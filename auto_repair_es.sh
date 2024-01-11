#! /bin/bash

# 顏色設定
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
WHITE="\033[0m"

echo -e "====================================================================\n
                      elasticsearch 自動修復工具
                          version: 0.0.2
                         By: CHUANG,PIN-YI
\n===================================================================="

run_count=0 # 計算執行次數，每 10 次顯示一次分片健康度

function health() {
    health_color=$(curl -sX GET "http://127.0.0.1:9200/_cat/health" | awk '{print $4}')
    case $health_color in
    green)
        color="${GREEN}"
        health_color="🟢"
        ;;
    yellow)
        color="${YELLOW}"
        health_color="🟡"
        ;;
    red)
        color="${RED}"
        health_color="🔴"
        ;;
    esac
    health_percent=$(curl -sX GET "http://127.0.0.1:9200/_cat/health" | awk '{print $NF}')
    echo -e "====================================================================\n
                ${BLUE}分片健康度：${color}${health_color}${BLUE} / 正常分片百分比：${GREEN}${health_percent}${WHITE}\n
===================================================================="
}

info=$(curl -sXGET "http://127.0.0.1:9200/_cluster/allocation/explain")

if [ $(echo $?) == "7" ]; then # 檢查連線是否成功
    echo -e "${RED}連線失敗，請先檢查是否有 port-forward 到對應的 svc 上 (9200 port)${WHITE}"
    echo -e "${BLUE}執行指令：${YELLOW}kubectl port-forward svc/<svc 名稱> 9200:9200 -n <namespace 名稱>${WHITE}\n"
    echo -e "${RED}或是檢查是否切換到正確的 Cluster 上 (與 namespace 有關)${WHITE}"
    echo -e "${BLUE}執行指令：${YELLOW}kubectl config use-context <gke 名稱>${WHITE}"
    exit
fi

while [[ ! $info =~ "unable to find any unassigned shards to explain" ]]; do # 檢查是否有 unassigned shards，沒有的話就繼續執行
    index=$(echo $info | jq -r .index)                                       # 取得 index 名稱
    shard=$(echo $info | jq -r .shard)                                       # 取得 shard 數量
    error_msg=$(echo $info | jq -r .allocate_explanation)                    # 取得錯誤訊息

    echo -e "\n${BLUE}Index: ${YELLOW}${index}${WHITE}"
    echo -e "${BLUE}Shard: ${YELLOW}${shard}${WHITE}"
    echo -e "${BLUE}Error Message: ${YELLOW}${error_msg}${WHITE}"

    if [ "$error_msg" == "allocation temporarily throttled" ] && [[ $info =~ "reached the limit of incoming shard recoveries" ]]; then
        echo -e "${BLUE}錯誤原因 : ${YELLOW}未分配分片太多，導致達到分片恢復的最大閥值，其他分片需要排隊等待${WHITE}"
        echo -e "${BLUE}解決辦法 : ${YELLOW}等待分片自行恢復，或是可以嘗試執行以下 API (請自行更換所需參數)${WHITE}"
        echo "
        PUT /_cluster/settings
        {
            "persistent": {
                "indices.recovery.max_bytes_per_sec": "1000mb", 
                "cluster.routing.allocation.node_concurrent_incoming_recoveries": 10,
                "cluster.routing.allocation.node_concurrent_recoveries": 10,
                "cluster.routing.allocation.cluster_concurrent_rebalance": 10
            }
        }
        "
        exit
    fi

    if [ "$error_msg" == "cannot allocate because a previous copy of the primary shard existed but can no longer be found on the nodes in the cluster" ]; then
        echo -e "${BLUE}錯誤原因 : ${YELLOW}主分片所在節點掉線 or 分片找不到可用節點${WHITE}"
        echo -e "${BLUE}解決辦法 : ${YELLOW}重新設定分片路由，讓分片可以分配到其他節點上${WHITE}"

        response=$(curl -sXPUT "http://127.0.0.1:9200/${index}/_settings?flat_settings=true" -H 'Content-Type: application/json' -d'
        {
            "index.routing.allocation.require._name": null
        }' | jq)

        echo -e "${BLUE}執行 API : ${YELLOW}_settings?flat_settings=true${WHITE}"
        if [[ $(echo "$response" | jq -r '.acknowledged') == "true" ]]; then
            echo -e "${BLUE}執行狀態 : ${GREEN}成功${WHITE}\n"
        else
            echo -e "${BLUE}執行狀態 : ${RED}失敗${WHITE}\n"
            echo $response
        fi
        exit
    fi

    if [ "$error_msg" == "cannot allocate because all found copies of the shard are either stale or corrupt" ] ||
        [ "$error_msg" == "cannot allocate because allocation is not permitted to any of the nodes" ]; then
        num_decisions=$(echo "$info" | jq -r '.node_allocation_decisions | length')
        while [ $num_decisions -gt 0 ]; do
            # 找出有問題的分片所在節點
            if [[ $(echo $info | jq -r .node_allocation_decisions[$((num_decisions - 1))].store.in_sync) == "false" ]]; then
                node_name=$(echo $info | jq -r .node_allocation_decisions[$((num_decisions - 1))].node_name)
            fi
            num_decisions=$((num_decisions - 1))
        done

        echo -e "${BLUE}錯誤原因 : ${YELLOW}節點長時間掉線後，再次加入群集，導致引入髒數據 or 同一節點上被分配同一主分片的副本 (節點掉線也會導致)${WHITE}"
        echo -e "${BLUE}解決辦法 : ${YELLOW}重新分配分片到其他節點上${WHITE}"

        response=$(curl -sXPOST "http://127.0.0.1:9200/_cluster/reroute?retry_failed=true" -H 'Content-Type: application/json' -d"
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
            echo -e "${BLUE}執行狀態 : ${GREEN}成功${WHITE}\n"
        else
            echo -e "${BLUE}執行狀態 : ${RED}失敗 (請檢查所有 Node 資源是否正常)${WHITE}"
            echo "$response"
        fi
        exit
    fi
    info=$(curl -sXGET "http://127.0.0.1:9200/_cluster/allocation/explain")

    # 每 10 次顯示一次分片健康度
    run_count=$((run_count + 1))
    if [ $run_count -eq 10 ]; then
        health
        run_count=0
    fi
done
echo -e "\n${BLUE}修復完成，請重新檢查分片健康度${WHITE}\n"
health
