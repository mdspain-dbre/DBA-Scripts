:rotating_light: *SQL Managed Instance `cs-sqlmi-01` — Provisioning Failure*

*Date of Failure:* April 16, 2026
*Resource:* `cs-sqlmi-01`
*Resource Group:* `content-services-documentdb`
*Subscription:* DRE-Sandbox (`148f67ee-68bc-429e-916b-4ca8568f3c6d`)
*Provisioning State:* Failed
*State:* CreationFailed

---

:mag: *Root Cause*

SQL MI provisioning failed due to the same *Azure Policy violation* that blocked the classic DMS deployment — the *Tagging Initiative Assignment* at the VIZIO management group level.

During provisioning, SQL MI creates internal networking resources (network intent policies) that *do not inherit tags* from the parent resource. The blocked resource was:

```
Error Code:        45465
Blocked Resource:  mi_default_2a39ca63-8d9b-4e06-855f-fca8c7a6b01f_10-18-16-192-26
Operation:         CREATE MANAGED SERVER (UpsertManagedServer)
Policy:            Require a tag on resources
Policy Definition: 871b6d14-10aa-478d-b590-94f262ecfa99
Policy Set:        Tagging Initiative
Policy Assignment: Tagging Initiative Assignment (Management Group: VIZIO)
```

This is the same `Require a tag on resources` policy that blocked the DMS classic deployment. SQL MI _always_ creates internal sub-resources during provisioning, and these cannot be tagged via Terraform or ARM templates.

---

:white_check_mark: *What Succeeded*

The following supporting resources were created successfully:
• Subnet: `dre-vnet1-sqlmi-subnet` (`10.18.16.192/26`)
• NSG: `cs-sqlmi-nsg`
• Route Table: `cs-sqlmi-rt`

Only the SQL MI instance itself failed.

---

:wrench: *Required Fix*

A *policy exemption* is required before SQL MI can be provisioned. Unlike DMS, there is no v2 alternative — SQL MI always creates internal networking resources.

Request an exemption from the Tagging Initiative team for one of:
• Resource type: `Microsoft.Sql/managedInstances`
• Resource group: `content-services-documentdb`
• Resource group: `DRE-sandbox-network-rg` (where network intent policies are created)

Once the exemption is in place, re-running `terraform apply` will pick up where it left off and create the SQL MI instance.
