$ErrorActionPreference = 'Continue'

# mall 环境状态一键快照：MySQL(DB) + Redis + RabbitMQ + 服务端口
# 用法：在 PowerShell 里直接运行，用于全链路验证每一步的「执行前 / 执行后」对比

$mysql  = 'D:\Java\mysql-8.0.34-winx64\bin\mysql.exe'
$redis  = 'C:\Program Files\Memurai\memurai-cli.exe'
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$skuId  = 99
$memberId = 1

function Title($t) { Write-Host ''; Write-Host "========== $t ==========" -ForegroundColor Cyan }

Title "时间"
Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Title "1. MySQL（mall 库）"
& $mysql -uroot -p1234 -N --default-character-set=utf8mb4 -e @"
SELECT CONCAT('订单总数=', COUNT(*), '  最大订单id=', IFNULL(MAX(id),0)) FROM mall.oms_order;
SELECT CONCAT('SKU=${skuId}: stock=', stock, '  lock_stock=', lock_stock, '  price=', price) FROM mall.pms_sku_stock WHERE id=$skuId;
SELECT CONCAT('会员 ${memberId} 购物车条数=', COUNT(*)) FROM mall.oms_cart_item WHERE member_id=$memberId;
SELECT CONCAT('最新订单: id=', id, ' sn=', order_sn, ' status=', status, ' pay_amount=', pay_amount) FROM mall.oms_order ORDER BY id DESC LIMIT 1;
"@ 2>$null

Title "2. Redis（Memurai）"
$keys = & $redis keys 'mall:*' 2>$null
if ($keys) {
    foreach ($k in $keys) {
        $type = (& $redis type $k 2>$null)
        $ttl  = (& $redis ttl  $k 2>$null)
        Write-Host ("  {0,-32} type={1,-6} ttl={2}s" -f $k, $type, $ttl)
    }
} else {
    Write-Host '  （暂无 mall:* 缓存，登录后会出现 token key）'
}
Write-Host ("  dbsize=" + (& $redis dbsize 2>$null))

Title "3. RabbitMQ（vhost /mall）"
& $docker exec mall-rabbitmq rabbitmqctl list_queues -p /mall name messages 2>&1 |
    Where-Object { $_ -notmatch 'Timeout|Listing' } | ForEach-Object { Write-Host "  $_" }

Title "4. 服务端口"
foreach ($p in 8080, 8085, 27017, 5672, 15672, 6379, 3306) {
    $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if ($c) { Write-Host "  $p LISTEN" -ForegroundColor Green } else { Write-Host "  $p -" -ForegroundColor DarkGray }
}

Title "5. 最近后端日志（各 3 行）"
foreach ($name in 'mall-admin', 'mall-portal') {
    $f = "$env:TEMP\$name-run.log"
    if (Test-Path $f) {
        Write-Host "  --- $name ---" -ForegroundColor DarkGray
        Get-Content $f -Tail 3 | ForEach-Object { Write-Host ("    " + $_.Substring(0, [Math]::Min(150, $_.Length))) }
    }
}
Write-Host ''
