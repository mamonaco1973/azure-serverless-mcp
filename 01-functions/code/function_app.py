import azure.functions as func
import json
import os
import logging
import calendar
import requests
from datetime import datetime, timezone, timedelta

from azure.identity import DefaultAzureCredential
from azure.mgmt.costmanagement import CostManagementClient
from azure.mgmt.costmanagement.models import (
    QueryDefinition,
    QueryDataset,
    QueryAggregation,
    QueryGrouping,
    QueryTimePeriod,
    ForecastDefinition,
    ForecastDataset,
    ForecastAggregation,
    ForecastTimePeriod,
)
import jwt
from jwt.algorithms import RSAAlgorithm

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]
API_CLIENT_ID   = os.environ["API_CLIENT_ID"]
TENANT_ID       = os.environ["TENANT_ID"]

SCOPE = f"/subscriptions/{SUBSCRIPTION_ID}"

_credential  = DefaultAzureCredential()
_cost_client = CostManagementClient(_credential)
_jwks_cache  = None

# ================================================================================
# Tool registry
# Single source of truth for tool metadata and routes. The proxy fetches this
# at startup via GET /tools so no tool definitions are hardcoded in proxy.sh.
# ================================================================================

TOOL_REGISTRY = [
    {
        "name": "get_month_to_date_cost",
        "description": (
            "Returns the total Azure spend from the first of the "
            "current month to today."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/month-to-date",
    },
    {
        "name": "get_cost_by_service",
        "description": (
            "Returns Azure spend broken down by service for the current "
            "month to date, sorted from highest to lowest."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/by-service",
    },
    {
        "name": "compare_this_month_to_last_month",
        "description": (
            "Compares this month's spend to the same number of days in "
            "the previous month and shows the delta and percentage change."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/compare-months",
    },
    {
        "name": "get_daily_cost_trend",
        "description": (
            "Returns the daily Azure spend for the current month with "
            "a running total."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/daily-trend",
    },
    {
        "name": "find_top_cost_drivers",
        "description": (
            "Returns the top 10 Azure services by spend for the current "
            "month with percentage share of total."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/top-drivers",
    },
    {
        "name": "forecast_month_end_cost",
        "description": (
            "Forecasts the projected total Azure spend for the remainder "
            "of the current month."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/cost/forecast",
    },
]


# ================================================================================
# Auth helpers
# ================================================================================

def _get_jwks() -> dict:
    """Fetch and cache Azure AD's JWKS for Bearer token signature validation.

    Returns:
        The JWKS document as a dict.
    """
    global _jwks_cache
    if _jwks_cache is None:
        url = (
            f"https://login.microsoftonline.com/"
            f"{TENANT_ID}/discovery/v2.0/keys"
        )
        _jwks_cache = requests.get(url, timeout=10).json()
    return _jwks_cache


def _validate_token(req: func.HttpRequest) -> bool:
    """Validate a service-principal Bearer JWT.

    Checks signature (via Azure AD JWKS), audience (must match
    API_CLIENT_ID), and expiry. Issuer is implicitly verified by
    the key lookup against the tenant-scoped JWKS endpoint.

    Args:
        req: The incoming HTTP request.

    Returns:
        True if the token is valid; False otherwise.
    """
    auth = req.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    token = auth[7:]
    try:
        header   = jwt.get_unverified_header(token)
        jwks     = _get_jwks()
        key_data = next(
            (k for k in jwks["keys"] if k["kid"] == header.get("kid")),
            None,
        )
        if key_data is None:
            return False
        public_key = RSAAlgorithm.from_jwk(json.dumps(key_data))
        jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=API_CLIENT_ID,
        )
        return True
    except Exception:
        return False


def _unauthorized() -> func.HttpResponse:
    return func.HttpResponse("Unauthorized", status_code=401)


def _audit_log(req: func.HttpRequest, tool: str) -> None:
    caller = req.headers.get("x-mcp-user", "unknown")
    logging.info("AUDIT tool=%s caller=%s", tool, caller)


# ================================================================================
# Cost Management helpers
# ================================================================================

def _today() -> datetime:
    return datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    )


def _mtd_window() -> tuple:
    """Return (start, end) covering the 1st of month through today.

    End is exclusive (tomorrow) so today's partial data is included.

    Returns:
        Tuple of (start_datetime, end_datetime).
    """
    today = _today()
    return today.replace(day=1), today + timedelta(days=1)


def _col_idx(columns, name: str) -> int:
    """Return the column index matching name; raises ValueError if absent.

    Args:
        columns: List of QueryColumn objects from a Cost Management result.
        name: Column name to find.

    Returns:
        Zero-based index of the column.

    Raises:
        ValueError: If no column with the given name exists.
    """
    for i, col in enumerate(columns):
        if col.name == name:
            return i
    available = [c.name for c in columns]
    raise ValueError(f"Column '{name}' not found. Available: {available}")


def _currency(columns, rows) -> str:
    """Extract the currency code from the first result row.

    Args:
        columns: Column list from a Cost Management result.
        rows: Row list from a Cost Management result.

    Returns:
        Currency string (e.g. "USD"), falling back to "USD" if not found.
    """
    idx = next(
        (i for i, c in enumerate(columns) if "currency" in c.name.lower()),
        None,
    )
    if idx is not None and rows:
        return str(rows[0][idx])
    return "USD"


def _query_total(start: datetime, end: datetime) -> tuple:
    """Query the total cost for a custom date range.

    Args:
        start: Inclusive start date.
        end: Exclusive end date.

    Returns:
        Tuple of (cost_float, currency_string).
    """
    result = _cost_client.query.usage(
        scope=SCOPE,
        parameters=QueryDefinition(
            type="ActualCost",
            timeframe="Custom",
            time_period=QueryTimePeriod(from_property=start, to=end),
            dataset=QueryDataset(
                granularity="None",
                aggregation={
                    "cost": QueryAggregation(name="PreTaxCost", function="Sum")
                },
            ),
        ),
    )
    if not result.rows:
        return 0.0, "USD"
    ci = _col_idx(result.columns, "cost")
    return float(result.rows[0][ci]), _currency(result.columns, result.rows)


def _text_resp(body: str) -> func.HttpResponse:
    return func.HttpResponse(body, status_code=200, mimetype="text/plain")


def _error_resp(msg: str) -> func.HttpResponse:
    return func.HttpResponse(msg, status_code=500, mimetype="text/plain")


# ================================================================================
# Routes
# ================================================================================

@app.route(route="tools", methods=["GET"])
def tools_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    return func.HttpResponse(
        json.dumps(TOOL_REGISTRY),
        status_code=200,
        mimetype="application/json",
    )


@app.route(route="cost/month-to-date", methods=["POST"])
def mtd_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "get_month_to_date_cost")
    try:
        start, end = _mtd_window()
        cost, currency = _query_total(start, end)
        today = _today()
        return _text_resp(
            f"Month-to-date cost ({today.strftime('%B %Y')}, "
            f"day {today.day}): {cost:,.2f} {currency}"
        )
    except Exception as exc:
        logging.error("mtd_handler: %s", exc)
        return _error_resp(str(exc))


@app.route(route="cost/by-service", methods=["POST"])
def by_service_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "get_cost_by_service")
    try:
        start, end = _mtd_window()
        result = _cost_client.query.usage(
            scope=SCOPE,
            parameters=QueryDefinition(
                type="ActualCost",
                timeframe="Custom",
                time_period=QueryTimePeriod(from_property=start, to=end),
                dataset=QueryDataset(
                    granularity="None",
                    aggregation={
                        "cost": QueryAggregation(
                            name="PreTaxCost", function="Sum"
                        )
                    },
                    grouping=[
                        QueryGrouping(type="Dimension", name="ServiceName")
                    ],
                ),
            ),
        )
        ci   = _col_idx(result.columns, "cost")
        si   = _col_idx(result.columns, "ServiceName")
        rows = sorted(result.rows, key=lambda r: float(r[ci]), reverse=True)
        today = _today()
        lines = [f"Cost by service ({today.strftime('%B %Y')} MTD):", ""]
        for row in rows:
            cost = float(row[ci])
            if cost > 0.01:
                svc = row[si] or "(unallocated)"
                lines.append(f"  {svc}: {cost:,.2f}")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("by_service_handler: %s", exc)
        return _error_resp(str(exc))


@app.route(route="cost/compare-months", methods=["POST"])
def compare_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "compare_this_month_to_last_month")
    try:
        today       = _today()
        mtd_start   = today.replace(day=1)
        mtd_end     = today + timedelta(days=1)

        # Last month: same day-count window, capped at that month's length.
        prev_last    = mtd_start - timedelta(days=1)
        prev_start   = prev_last.replace(day=1)
        prev_days    = calendar.monthrange(prev_last.year, prev_last.month)[1]
        prev_end_day = min(today.day, prev_days)
        prev_end     = prev_start.replace(day=prev_end_day) + timedelta(days=1)

        this_cost, currency = _query_total(mtd_start, mtd_end)
        prev_cost, _        = _query_total(prev_start, prev_end)

        delta = this_cost - prev_cost
        pct   = (delta / prev_cost * 100) if prev_cost else 0.0
        sign  = "+" if delta >= 0 else ""

        lines = [
            f"Month-over-month comparison (day 1–{today.day}):",
            f"  {today.strftime('%B %Y')} MTD:             "
            f"{this_cost:>10,.2f} {currency}",
            f"  {prev_last.strftime('%B %Y')} (same period): "
            f"{prev_cost:>10,.2f} {currency}",
            f"  Delta: {sign}{delta:,.2f} {currency} ({sign}{pct:.1f}%)",
        ]
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("compare_handler: %s", exc)
        return _error_resp(str(exc))


@app.route(route="cost/daily-trend", methods=["POST"])
def daily_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "get_daily_cost_trend")
    try:
        start, end = _mtd_window()
        result = _cost_client.query.usage(
            scope=SCOPE,
            parameters=QueryDefinition(
                type="ActualCost",
                timeframe="Custom",
                time_period=QueryTimePeriod(from_property=start, to=end),
                dataset=QueryDataset(
                    granularity="Daily",
                    aggregation={
                        "cost": QueryAggregation(
                            name="PreTaxCost", function="Sum"
                        )
                    },
                ),
            ),
        )
        ci   = _col_idx(result.columns, "cost")
        di   = _col_idx(result.columns, "UsageDate")
        rows = sorted(result.rows, key=lambda r: r[di])
        today = _today()
        lines = [f"Daily cost trend ({today.strftime('%B %Y')} MTD):", ""]
        running = 0.0
        for row in rows:
            cost      = float(row[ci])
            running  += cost
            # UsageDate is an integer in YYYYMMDD format.
            d         = str(int(row[di]))
            date_str  = f"{d[:4]}-{d[4:6]}-{d[6:]}"
            lines.append(
                f"  {date_str}: {cost:>8,.2f}  "
                f"(running: {running:,.2f})"
            )
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("daily_handler: %s", exc)
        return _error_resp(str(exc))


@app.route(route="cost/top-drivers", methods=["POST"])
def top_drivers_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "find_top_cost_drivers")
    try:
        start, end = _mtd_window()
        result = _cost_client.query.usage(
            scope=SCOPE,
            parameters=QueryDefinition(
                type="ActualCost",
                timeframe="Custom",
                time_period=QueryTimePeriod(from_property=start, to=end),
                dataset=QueryDataset(
                    granularity="None",
                    aggregation={
                        "cost": QueryAggregation(
                            name="PreTaxCost", function="Sum"
                        )
                    },
                    grouping=[
                        QueryGrouping(type="Dimension", name="ServiceName")
                    ],
                ),
            ),
        )
        ci    = _col_idx(result.columns, "cost")
        si    = _col_idx(result.columns, "ServiceName")
        all_rows = sorted(
            result.rows, key=lambda r: float(r[ci]), reverse=True
        )
        top   = all_rows[:10]
        total = sum(float(r[ci]) for r in all_rows)
        today = _today()
        lines = [f"Top cost drivers ({today.strftime('%B %Y')} MTD):", ""]
        for rank, row in enumerate(top, 1):
            cost = float(row[ci])
            svc  = row[si] or "(unallocated)"
            pct  = (cost / total * 100) if total else 0.0
            lines.append(f"  {rank:2d}. {svc}: {cost:,.2f} ({pct:.1f}%)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("top_drivers_handler: %s", exc)
        return _error_resp(str(exc))


@app.route(route="cost/forecast", methods=["POST"])
def forecast_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "forecast_month_end_cost")
    try:
        today        = _today()
        last_day     = calendar.monthrange(today.year, today.month)[1]
        # Forecast from today through the last day of the month (exclusive end).
        forecast_end = today.replace(day=last_day) + timedelta(days=1)

        # Actual MTD gives the already-incurred portion of the month.
        mtd_cost, currency = _query_total(today.replace(day=1), today)

        result = _cost_client.forecast.usage(
            scope=SCOPE,
            parameters=ForecastDefinition(
                type="ActualCost",
                timeframe="Custom",
                time_period=ForecastTimePeriod(
                    from_property=today,
                    to=forecast_end,
                ),
                dataset=ForecastDataset(
                    granularity="Monthly",
                    aggregation={
                        "cost": ForecastAggregation(
                            name="PreTaxCost", function="Sum"
                        )
                    },
                ),
                include_actual_cost=False,
                include_fresh_partial_cost=False,
            ),
        )
        ci            = _col_idx(result.columns, "cost")
        remaining     = sum(float(r[ci]) for r in result.rows)
        projected     = mtd_cost + remaining

        return _text_resp(
            f"Month-end forecast ({today.strftime('%B %Y')}):\n"
            f"  Actual MTD (through day {today.day}): {mtd_cost:,.2f} {currency}\n"
            f"  Projected remaining:                  {remaining:,.2f} {currency}\n"
            f"  Projected month-end total:            {projected:,.2f} {currency}"
        )
    except Exception as exc:
        logging.error("forecast_handler: %s", exc)
        return _error_resp(str(exc))
