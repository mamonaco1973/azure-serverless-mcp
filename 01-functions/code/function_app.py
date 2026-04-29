import azure.functions as func
import json
import os
import logging
import requests

from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions
import jwt
from jwt.algorithms import RSAAlgorithm

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]
API_CLIENT_ID   = os.environ["API_CLIENT_ID"]
TENANT_ID       = os.environ["TENANT_ID"]

_credential = DefaultAzureCredential()
_rg_client  = ResourceGraphClient(_credential)
_jwks_cache = None

# ================================================================================
# Tool registry
# Single source of truth for tool metadata and routes. The proxy fetches this
# at startup via GET /tools so no tool definitions are hardcoded in proxy.sh.
# ================================================================================

TOOL_REGISTRY = [
    {
        "name": "list_virtual_machines",
        "description": (
            "Lists all virtual machines in the subscription with "
            "name, resource group, location, and VM size."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/virtual-machines",
    },
    {
        "name": "list_resource_groups",
        "description": (
            "Lists all resource groups in the subscription with "
            "name, location, and tag count."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/resource-groups",
    },
    {
        "name": "count_resources_by_type",
        "description": (
            "Returns a ranked count of all resource types deployed "
            "in the subscription."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/count-by-type",
    },
    {
        "name": "find_resources_by_tag",
        "description": "Finds all resources matching a specific tag key and value.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tag_key": {
                    "type": "string",
                    "description": "Tag key to search for",
                },
                "tag_value": {
                    "type": "string",
                    "description": "Tag value to match",
                },
            },
            "required": ["tag_key", "tag_value"],
        },
        "route": "/resources/by-tag",
    },
    {
        "name": "list_public_ip_addresses",
        "description": (
            "Lists all public IP addresses in the subscription with "
            "their assigned resource and allocation method."
        ),
        "inputSchema": {"type": "object", "properties": {}, "required": []},
        "route": "/resources/public-ips",
    },
    {
        "name": "find_resources_by_region",
        "description": (
            "Lists all resources deployed in a specific Azure region "
            "(e.g. 'eastus', 'westeurope')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {
                    "type": "string",
                    "description": "Azure region name, e.g. 'eastus'",
                },
            },
            "required": ["region"],
        },
        "route": "/resources/by-region",
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
    API_CLIENT_ID), and expiry.

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
# Resource Graph helpers
# ================================================================================

def _rg_query(kql: str) -> list:
    """Execute a Resource Graph KQL query and return rows as a list of dicts.

    Uses objectArray result format so each row is a plain dict — no
    column-index lookup required.

    Args:
        kql: KQL query string.

    Returns:
        List of dicts, one per result row. Empty list if no results.
    """
    request = QueryRequest(
        subscriptions=[SUBSCRIPTION_ID],
        query=kql,
        options=QueryRequestOptions(result_format="objectArray"),
    )
    result = _rg_client.resources(request)
    return result.data or []


def _text_resp(body: str) -> func.HttpResponse:
    return func.HttpResponse(body, status_code=200, mimetype="text/plain")


def _error_resp(exc: Exception) -> func.HttpResponse:
    return func.HttpResponse(str(exc), status_code=500, mimetype="text/plain")


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


@app.route(route="resources/virtual-machines", methods=["POST"])
def vms_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "list_virtual_machines")
    try:
        rows = _rg_query("""
            Resources
            | where type =~ 'microsoft.compute/virtualmachines'
            | project name, resourceGroup, location,
                vmSize = tostring(properties.hardwareProfile.vmSize)
            | order by name asc
        """)
        lines = [f"Virtual machines ({len(rows)} total):", ""]
        for r in rows:
            lines.append(
                f"  {r['name']:<30}  {r['vmSize']:<20}  "
                f"{r['resourceGroup']}  ({r['location']})"
            )
        if not rows:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("vms_handler: %s", exc)
        return _error_resp(exc)


@app.route(route="resources/resource-groups", methods=["POST"])
def rgs_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "list_resource_groups")
    try:
        rows = _rg_query("""
            ResourceContainers
            | where type =~ 'microsoft.resources/subscriptions/resourcegroups'
            | project name, location,
                tagCount = array_length(bag_keys(tags))
            | order by name asc
        """)
        lines = [f"Resource groups ({len(rows)} total):", ""]
        for r in rows:
            tc   = r.get("tagCount") or 0
            tags = f"  ({tc} tag{'s' if tc != 1 else ''})" if tc else ""
            lines.append(f"  {r['name']:<40}  {r['location']}{tags}")
        if not rows:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("rgs_handler: %s", exc)
        return _error_resp(exc)


@app.route(route="resources/count-by-type", methods=["POST"])
def count_by_type_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "count_resources_by_type")
    try:
        rows  = _rg_query("""
            Resources
            | summarize count() by type
            | order by count_ desc
        """)
        total = sum(r["count_"] for r in rows)
        lines = [f"Resources by type ({total} total):", ""]
        for r in rows:
            lines.append(f"  {r['count_']:>5}  {r['type']}")
        if not rows:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("count_by_type_handler: %s", exc)
        return _error_resp(exc)


@app.route(route="resources/by-tag", methods=["POST"])
def by_tag_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "find_resources_by_tag")
    try:
        body      = req.get_json(silent=True) or {}
        tag_key   = str(body.get("tag_key",   "")).strip()
        tag_value = str(body.get("tag_value", "")).strip()
        if not tag_key or not tag_value:
            return func.HttpResponse(
                "tag_key and tag_value are required", status_code=400
            )
        # Escape single quotes to prevent KQL injection.
        kql_key = tag_key.replace("'", "''")
        kql_val = tag_value.replace("'", "''")
        rows = _rg_query(f"""
            Resources
            | where tags['{kql_key}'] =~ '{kql_val}'
            | project name, type, resourceGroup, location
            | order by name asc
        """)
        lines = [f"Resources tagged {tag_key}={tag_value} ({len(rows)} found):", ""]
        for r in rows:
            lines.append(
                f"  {r['name']:<30}  {r['type']:<50}  "
                f"{r['resourceGroup']}  ({r['location']})"
            )
        if not rows:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("by_tag_handler: %s", exc)
        return _error_resp(exc)


@app.route(route="resources/public-ips", methods=["POST"])
def public_ips_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "list_public_ip_addresses")
    try:
        rows = _rg_query("""
            Resources
            | where type =~ 'microsoft.network/publicipaddresses'
            | project name, resourceGroup, location,
                ipAddress        = tostring(properties.ipAddress),
                allocationMethod = tostring(properties.publicIPAllocationMethod)
            | order by name asc
        """)
        lines = [f"Public IP addresses ({len(rows)} total):", ""]
        for r in rows:
            ip     = r.get("ipAddress") or "(unassigned)"
            method = r.get("allocationMethod", "")
            lines.append(
                f"  {r['name']:<30}  {ip:<18}  {method:<10}  "
                f"{r['resourceGroup']}  ({r['location']})"
            )
        if not rows:
            lines.append("  (none found)")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("public_ips_handler: %s", exc)
        return _error_resp(exc)


@app.route(route="resources/by-region", methods=["POST"])
def by_region_handler(req: func.HttpRequest) -> func.HttpResponse:
    if not _validate_token(req):
        return _unauthorized()
    _audit_log(req, "find_resources_by_region")
    try:
        body   = req.get_json(silent=True) or {}
        region = str(body.get("region", "")).strip().lower()
        if not region:
            return func.HttpResponse("region is required", status_code=400)
        kql_region = region.replace("'", "''")
        rows = _rg_query(f"""
            Resources
            | where location =~ '{kql_region}'
            | project name, type, resourceGroup
            | order by type asc, name asc
        """)
        lines = [f"Resources in {region} ({len(rows)} total):", ""]
        for r in rows:
            lines.append(
                f"  {r['name']:<30}  {r['type']:<50}  {r['resourceGroup']}"
            )
        if not rows:
            lines.append(f"  (no resources found in {region})")
        return _text_resp("\n".join(lines))
    except Exception as exc:
        logging.error("by_region_handler: %s", exc)
        return _error_resp(exc)
