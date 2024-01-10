#! /bin/bash

# 顏色設定
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
WHITE="\033[0m"

# kubectl port-forward svc/bbgp-es-logging-1-elasticsearch-svc 9200:9200 -n hex &

echo -e "====================================================================\n
                      elasticsearch 自動修復工具
                          version: 1.0.0
                          By: CHUANG,PIN-YI

===================================================================="

info=$(curl -sXGET "http://127.0.0.1:9200/_cluster/allocation/explain")
run_count=0

while [[ $(echo $info | jq -r '.error.reason == null') == "true" ]]; do
    index=$(echo $info | jq -r .index)
    shard=$(echo $info | jq -r .shard)
    error_msg=$(echo $info | jq -r .allocate_explanation)

    echo -e "\n${BLUE}Index: ${YELLOW}${index}${WHITE}"
    echo -e "${BLUE}Shard: ${YELLOW}${shard}${WHITE}"
    echo -e "${BLUE}Error Message: ${YELLOW}${error_msg}${WHITE}"

    # cannot allocate because a previous copy of the primary shard existed but can no longer be found on the nodes in the cluster (/_settings?flat_settings=true)
    if [ "$error_msg" == "cannot allocate because a previous copy of the primary shard existed but can no longer be found on the nodes in the cluster" ]; then
        response=$(curl -sXPUT "http://127.0.0.1:9200/${index}/_settings?flat_settings=true" -H 'Content-Type: application/json' -d'
        {
            "index.routing.allocation.require._name": null
        }' | jq)

        echo -e "${BLUE}執行 API : ${YELLOW}_settings?flat_settings=true${WHITE}"
        if [[ $(echo "$response" | jq -r '.acknowledged') == "true" ]]; then
            echo -e "${BLUE}狀態:${GREEN}成功${WHITE}\n"
        else
            echo -e "${BLUE}狀態:${RED}失敗${WHITE}\n"
        fi
    fi

    # cannot allocate because all found copies of the shard are either stale or corrupt (/_cluster/reroute)
    if [ "$error_msg" == "cannot allocate because all found copies of the shard are either stale or corrupt" ]; then
        num_decisions=$(echo "$info" | jq -r '.node_allocation_decisions | length')
        while [ $num_decisions -gt 0 ]; do
            if [[ $(echo $info | jq -r .node_allocation_decisions[$((num_decisions - 1))].store.in_sync) == "false" ]]; then
                node_name=$(echo $info | jq -r .node_allocation_decisions[$((num_decisions - 1))].node_name)
            fi
            num_decisions=$((num_decisions - 1))
        done

        response=$(curl -sXPOST "http://127.0.0.1:9200/_cluster/reroute" -H 'Content-Type: application/json' -d"
        {
        \"commands\": [
            {
            \"allocate_stale_primary\": {
                \"index\": \"$index\",
                \"shard\": $shard,
                \"node\": \"$node_name\",
                \"accept_data_loss\": true
            }
            }
        ]
        }" | jq)

        echo -e "${BLUE}執行 API : ${YELLOW}/_cluster/reroute${WHITE}"
        if [[ $(echo "$response" | jq -r '.acknowledged') == "true" ]]; then
            echo -e "${BLUE}狀態:${GREEN}成功${WHITE}\n"
        else
            echo -e "${BLUE}狀態:${RED}失敗${WHITE}\n"
        fi
    fi
    info=$(curl -sXGET "http://127.0.0.1:9200/_cluster/allocation/explain")

    # 每 10 次顯示一次分片健康度
    run_count=$((run_count + 1))
    if [ $run_count -eq 10 ]; then
        health_color=$(curl -sX GET "http://127.0.0.1:9200/_cat/health" | awk '{print $4}')
        health_percent=$(curl -sX GET "http://127.0.0.1:9200/_cat/health" | awk '{print $NF}')
        echo -e "====================================================================\n
        ${BLUE}分片健康度：${YELLOW}${health_color} ${BLUE} / 正常分片百分比：${GREEN}${health_percent}${WHITE}\n
===================================================================="
        run_count=0
    fi
done
