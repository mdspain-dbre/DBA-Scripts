locals {
  dbms_engine = "postgres"

  # Required by the gcp-clouddns submodule (invoked via dns_a_records).
  # Validation enforces all 8 keys: environment, team, owner, function,
  # service, monitoring, repo, iac-repo.
  labels = {
    environment = var.environment
    team        = "cpie-dre"
    owner       = "cpie-dre"
    function    = "tvc"                                       # TODO: confirm
    service     = var.service
    monitoring  = "cpie-dre@vizio.com"
    repo        = "CognitiveNetworks/evergreen-inscape-iac"   # TODO: confirm app repo
    "iac-repo"  = "CognitiveNetworks/DBA-Scripts"             # TODO: confirm IaC repo
  }
}
