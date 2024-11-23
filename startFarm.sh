#!/bin/bash

reward_address=subotW1z1Qd5kYJykkp1WLqFahHHAP59gPW6NqnPSixWFbDLc
RPC_URL=ws://10.1.22.240:9944
# 获取df -h输出并提取路径和大小
df_output=$(df)
server_name=$(hostname)
server_ip=$(hostname -I | awk '{print $1}')

# 初始化paths, sizes 和 indexes数组
paths=()
sizes=()
indexes=()

# 初始化日志监控相关变量
LOG_FILE="/data/subspace/farm.log"
declare -A PLOTTING_FARMS
declare -A PLOTTING_PROGRESS
declare -A recorded_rewards
MAX_IDLE_TIME=30  # 最大空闲时间 5 分钟
START_TIME=$(date +%s)
last_position=0
restart_status=0

mode="CPU"  # 默认模式为CPU
max_farm=16

# 提取路径和大小
findex=0
while read -r line; do
    if [[ "$line" =~ ^/dev/nvme ]]; then
        path=$(echo $line | awk '{print $6}')
        size=$(echo $line | awk '{print $2}')
		size_without_1_percent=$((size * 96 / 100))
		size_without_1_percent="$size_without_1_percent"KiB
        paths+=("$path")
        sizes+=("$size_without_1_percent")
		indexes+=("$findex")
		findex=$((findex + 1))
		# echo "$path ： $size_without_1_percent"
    fi
done <<< "$df_output"

# 创建启动命令
start_cmd="./subspaceFarmer farm --reward-address $reward_address --node-rpc-url $RPC_URL --cpu-sector-encoding-concurrency 0 --max-plotting-sectors-per-farm 12 --cuda-sector-downloading-concurrency 12 --listen-on /ip4/0.0.0.0/tcp/30533 --cache-percentage 3 --prometheus-listen-on 0.0.0.0:8181"

for i in "${!paths[@]}"; do
    start_cmd+=" path=${paths[$i]},size=${sizes[$i]}"
done

# 打印启动命令
cd /data/subspace && nohup $start_cmd > $LOG_FILE 2>&1 &

# 初始化一个数组来存储plot的时间戳
plot_timestamps=()
average_plot_time=-1
calculate_average_plot_time() {
    local count=${#plot_timestamps[@]}
    if [[ $count -lt 2 ]]; then
        average_plot_time=0
        return
    fi
    
    # 计算最近60次plot时间差的总和
    local total_time_diff=0
    for ((i=1; i<count; i++)); do
        local diff=$((plot_timestamps[i] - plot_timestamps[i-1]))
        total_time_diff=$((total_time_diff + diff))
    done

    # 计算平均每次plot耗时
    average_plot_time=$(echo "scale=2; $total_time_diff / ($count - 1)" | bc)
}

# 更新绘制进度的通用函数
start_plot_pre=0
update_progress() {
    local farm_index=$1
    local status=$2
    local progress=$3
	local log_line=$4  # 传递当前的日志行
    PLOTTING_FARMS[$farm_index]=$status
    PLOTTING_PROGRESS[$farm_index]=$progress

	if [[ $start_plot_pre == 1 ]]; then
		# 检查状态并更新时间戳（包括 plotting 和 replotting 的状态）
		if [[ "$status" == "Plotted" || "$status" == "Replotting" || "$status" == "Plotting" ]]; then
			local plot_time=$(echo "$log_line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z')
			local plot_time_epoch=$(date -d "$plot_time" '+%s')

			# 更新 plot_timestamps 数组，保留最近 60 个时间戳
			plot_timestamps+=("$plot_time_epoch")
			if [[ ${#plot_timestamps[@]} -gt 101 ]]; then
				plot_timestamps=("${plot_timestamps[@]:1}")
			fi

			# 计算平均 plot 耗时
			calculate_average_plot_time
		fi
	fi
}

# 检查日志并更新进度
check_log() {

    local last_log_line=$(tail -n 1 "$LOG_FILE")
    local current_line_count=$(wc -l < "$LOG_FILE")
	
	# 检查是否为GPU模式
    if grep -q "subspace_farmer::commands::farm: Using CUDA GPUs used_cuda_devices=" "$LOG_FILE"; then
        mode="GPU"
    fi

    # 记录最后一条日志的时间
    if [[ -n "$last_log_line" ]]; then
        last_log_timestamp=$(echo "$last_log_line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z')

        if [[ -n "$last_log_timestamp" ]]; then
            last_log_time_utc=$(date -d "$last_log_timestamp" '+%s')
            last_log_time_utc8=$(date -d @"$last_log_time_utc" '+%Y-%m-%d %H:%M:%S' -u)
            last_log_time_utc8=$(date -d "$last_log_time_utc8 UTC" '+%Y-%m-%d %H:%M:%S')
        else
            last_log_time_utc8="1970-01-01 00:00:00"
        fi
    fi

    local previous_log_line=""
    if [[ "$last_position" -lt "$current_line_count" ]]; then
        while IFS= read -r log_line; do
			echo "$log_line"
			
            # 更新进度
			if [[ "$log_line" == *"farmer_cache: Finished piece cache synchronization"* ]]; then
				start_plot_pre=1
			fi
            if [[ "$log_line" == *"Synchronizing piece cache"* ]]; then
                previous_log_line="$log_line"
            elif [[ "$log_line" == *"Finished piece cache synchronization"* && "$previous_log_line" == *"Synchronizing piece cache"* ]]; then
                for farm_index in "${!PLOTTING_PROGRESS[@]}"; do
                    update_progress $farm_index "Plotted" 100 $log_line
                done
                previous_log_line=""
            elif [[ "$log_line" == *"subspace_farmer::single_disk_farm::plotting: Initial plotting complete"* ]]; then
                local farm_index=$(echo "$log_line" | grep -oP 'farm_index=\K[0-9]+')
                update_progress $farm_index "Plotted" 100 $log_line
            elif [[ "$log_line" == *"subspace_farmer::single_disk_farm::plotting: Plotting sector"* ]]; then
                local farm_index=$(echo "$log_line" | grep -oP 'farm_index=\K[0-9]+')
                local progress=$(echo "$log_line" | grep -oP 'Plotting sector \(\K[0-9.]+')
                update_progress $farm_index "Plotting" $progress $log_line
            elif [[ "$log_line" == *"subspace_farmer::single_disk_farm::plotting: Replotting sector"* ]]; then
                local farm_index=$(echo "$log_line" | grep -oP 'farm_index=\K[0-9]+')
                local replotting_progress=$(echo "$log_line" | grep -oP 'Replotting sector \(\K[0-9.]+')
                update_progress $farm_index "Replotting" $replotting_progress $log_line
            elif [[ "$log_line" == *"subspace_farmer::single_disk_farm::plotting: Replotting complete"* ]]; then
                local farm_index=$(echo "$log_line" | grep -oP 'farm_index=\K[0-9]+')
                update_progress $farm_index "Plotted" 100 $log_line
			elif [[ "$log_line" == *"subspace_farmer::farmer_cache: Piece cache sync"* ]]; then
				local piece_cache=$(echo "$log_line" | grep -oE 'Piece cache sync [0-9]+\.[0-9]+%' | grep -oE '[0-9]+\.[0-9]+')
				average_plot_time="Piece cache sync $piece_cache% complete"
				start_plot_pre=0
				declare -A plot_timestamps
            fi

            last_position=$((last_position + 1))
        done < <(tail -n +$((last_position + 1)) "$LOG_FILE")
        
        local current_time=$(date +%s)
        log_time_diff=$((current_time - last_log_time_utc))
    else
        sleep $MAX_IDLE_TIME
    fi
}

# 转换秒数为天、小时、分钟、秒的格式
convert_seconds() {
    local total_seconds=$1
    local days=$((total_seconds / 86400))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))
	local seconds_view
	if [[ $days -gt 0 ]]; then
		echo "${days}天 ${hours}小时 ${minutes}分钟 ${seconds}秒"
	elif [[ $hours -gt 0 ]]; then
		echo "${hours}小时 ${minutes}分钟 ${seconds}秒"
	elif [[ $minutes -gt 0 ]]; then
		echo "${minutes}分钟 ${seconds}秒"
	else
		echo "${seconds}秒"
	fi

    # echo "${days}天 ${hours}小时 ${minutes}分钟 ${seconds}秒"
}


# 显示当前状态
display_status() {
	clear
    echo "------------------------------------- 当前状态 ---------------------------------------------------------"
	printf "%-60s %s\n" "本机名称:" "$server_name"
	printf "%-60s %s\n" "本机地址:" "$server_ip"
    printf "%-60s %s\n" "节点地址:" "$RPC_URL"
    printf "%-60s %s\n" "钱包地址:" "$reward_address"
	printf "%-60s %s\n" "启动模式:" "$mode"
    echo "--------------------------------------------------------------------------------------------------------"
    printf "%-60s %s\n" "当前时间:" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%-60s %s\n" "最后时间:" "$last_log_time_utc8"
    printf "%-60s %s\n" "相差时间:" "$(convert_seconds $(( $(date -d "$(date '+%Y-%m-%d %H:%M:%S')" '+%s') - last_log_time_utc )))"
    printf "%-60s %s\n" "运行时间:" "$(convert_seconds $(( $(date -d "$(date '+%Y-%m-%d %H:%M:%S')" '+%s') - START_TIME )))"
	printf "%-60s %s\n" "单图时间:" "$average_plot_time"

	local Progress=0
	local count=0
	for index in "${indexes[@]}"; do
		local size=${sizes[$index]}
		local size_value=$(echo $size | sed 's/KiB//')
		local size_GB=$(echo "scale=2; $size_value / 1024 / 1024" | bc)
		local size_TB=$(echo "scale=2; $size_value / 1024 / 1024 / 1024" | bc)
		if (( $(echo "$size_TB < 1" | bc -l) )); then
		  local size_view="${size_GB} GiB"
		else
		  local size_view="${size_TB} TiB"
		fi
		# 检查是否已经开始绘制
        if [ -z "${PLOTTING_FARMS[$index]}" ]; then
            printf "%-60s %s\n" "${paths[$index]}($index):" "Not Started - $size_view"
        else
            printf "%-60s %s\n" "${paths[$index]}($index):" "${PLOTTING_FARMS[$index]} ( ${PLOTTING_PROGRESS[$index]}%) - $size_view"
			if [[ ${PLOTTING_FARMS[$index]} == "Plotting" || ${PLOTTING_FARMS[$index]} == "Plotted" || ${PLOTTING_FARMS[$index]} == "Replotting" ]]; then
				count=$((count+1))
				Progress=$(echo "scale=2; $Progress + ${PLOTTING_PROGRESS[$index]}" | bc)
			fi
        fi
	done
	
	if(( $count>0 )); then
		Progress=$(echo "scale=2; $Progress / $count" | bc)
		if (( $(echo "$Progress == 100" | bc -l) )); then
			restart_status=0
		else
			restart_status=1
		fi
	fi
	
	printf "%-60s %s\n" "整体进度:" "$Progress%"
    echo "--------------------------------------------------------------------------------------------------------"
	# local last_logs=$(tail -n 10 "$LOG_FILE")
    # echo "$last_logs"
	# echo "cd /data/subspace && nohup $start_cmd > $LOG_FILE 2>&1 &"
	
}

# 启动并检测日志是否超时
monitor_and_restart() {
    while true; do
        check_log
        display_status

        # if [[ -n "$last_log_time_utc8" && "$last_log_time_utc8" != "1970-01-01 00:00:00" ]]; then
        #     local last_log_time=$(date -d "$last_log_time_utc8" +%s)
        #     local current_time=$(date +%s)
        #     local time_diff=$((current_time - last_log_time))
		# 
        #     if [[ $restart_status == 1 && $time_diff -gt 300 ]]; then
        #         echo "日志超时超过5分钟，重启程序..."
        #         pkill -9 -f "subspaceFarmer"
        #         sleep 90
        #         cd /data/subspace && nohup $start_cmd > $LOG_FILE 2>&1 &
        #     fi
        # fi
        sleep 6
    done
}


# 调用监控函数开始执行
monitor_and_restart
