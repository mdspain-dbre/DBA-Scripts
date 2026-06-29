locals {
  dbms_engine = "postgres"

  # Required by the gcp-clouddns submodule (invoked via dns_a_records).
  # Validation enforces all 8 keys: environment, team, owner, function,
  # service, monitoring, repo, iac-repo.
  labels = {
    environment = var.environment
    team        = "cpie-dre"
    owner       = "cpie-dre"
    function    = "tvc" # TODO: confirm
    service     = var.service
    repo        = "cognitivenetworks_evergreen-inscape-iac" # TODO: confirm app repo
  }
}
