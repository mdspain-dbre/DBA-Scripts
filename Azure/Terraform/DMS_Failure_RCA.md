:rotating_light: *DMS `cs-dms-01` — Root Cause Analysis*

*Date of Failure:* April 14, 2026
*Resource:* `cs-dms-01`
*Resource Group:* `content-services-documentdb`
*Subscription:* DRE-Sandbox (`148f67ee-68bc-429e-916b-4ca8568f3c6d`)
*Provisioning State:* Failed

---

:mag: *Root Cause*

The DMS provisioning failed due to an *Azure Policy violation* enforced by the *Tagging Initiative Assignment* at the VIZIO management group level.

When DMS provisions, it internally creates sub-resources (e.g., a NIC named `NIC-5m7syg9vvhxxgwavzwug4di6`). These internally-created resources *do not inherit the tags* set on the parent DMS resource, causing them to violate the tagging policy.

```
Policy:               Require a tag on resources
Policy Definition ID: 871b6d14-10aa-478d-b590-94f262ecfa99
Policy Set:           Tagging Initiative
Policy Assignment:    Tagging Initiative Assignment (Management Group: VIZIO)
Blocked Resource:     NIC-5m7syg9vvhxxgwavzwug4di6
Violation Count:      10 (one per required tag)
```

The 10 required tags missing from the internal NIC:
`apmid` · `applicationname` · `cost-center` · `created-by` · `environment` · `function` · `name` · `notificationdistlist` · `owner` · `repo`

---

:wrench: *Fix Options*

*1. Request a Policy Exemption* :white_check_mark: _(Recommended)_
Request an exemption from the team managing the Tagging Initiative for `Microsoft.DataMigration/services` resources or for the `content-services-documentdb` resource group. This is the cleanest fix since DMS internal sub-resources cannot be tagged via Terraform or ARM templates.

*2. Add a Policy Exclusion for DMS Internal Resources*
Scope out `Microsoft.Network/networkInterfaces` resources whose names match the DMS internal naming pattern from the tagging policy. This is broader than ideal and may require coordination with the policy owners.

*3. Use Azure Database Migration Service v2*
The newer DMS v2 runs as an Azure SQL Migration extension on a self-hosted integration runtime rather than deploying its own VNet-attached infrastructure. This avoids the sub-resource tagging problem entirely since no internal NICs are created.
