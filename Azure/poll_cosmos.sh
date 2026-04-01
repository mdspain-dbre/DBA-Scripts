#!/bin/bash
while true; do
    state=$(az cosmosdb show --name contentservicecosmosdbtestv6 -g content-services-documentdb --query provisioningState -o tsv 2>/dev/null)
    vnets=$(az cosmosdb show --name contentservicecosmosdbtestv6 -g content-services-documentdb --query "length(virtualNetworkRules)" -o tsv 2>/dev/null)
    echo "$(date '+%H:%M:%S') - state: $state, vnetRules: $vnets"
    if [ "$state" = "Succeeded" ] && [ "$vnets" -gt 0 ]; then
        echo "VNet rule applied!"
        break
    fi
    sleep 60
done
