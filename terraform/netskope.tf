# Netskope provider resources — cloud-agnostic, identical to the AWS implementation.
#
# The Netskope provider creates publisher records and generates one-time registration
# tokens. It does not manage any GCP infrastructure.
#
# Authentication: REST API v2 token (set via TF_VAR_netskope_api_key).

resource "netskope_npa_publisher" "this" {
  for_each       = local.publishers
  publisher_name = each.value.name
}

resource "netskope_npa_publisher_token" "this" {
  for_each     = local.publishers
  publisher_id = netskope_npa_publisher.this[each.key].publisher_id
}