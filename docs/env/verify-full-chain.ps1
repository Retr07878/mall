$ErrorActionPreference = 'Continue'

$base  = 'http://localhost:8085'
$mysql = 'D:\Java\mysql-8.0.34-winx64\bin\mysql.exe'
$docker= 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$log   = 'C:\Users\齐政砚\AppData\Local\Temp\verify-chain.log'
$tmp   = "$env:TEMP\mall-verify"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$utf8  = New-Object System.Text.UTF8Encoding($false)
$results = New-Object System.Collections.ArrayList

function L($m) { $s = "$(Get-Date -Format 'HH:mm:ss')  $m"; Add-Content -Path $log -Value $s -Encoding UTF8; Write-Host $s }
function BodyFile($name, $json) { $p = Join-Path $tmp $name; [System.IO.File]::WriteAllText($p, $json, $utf8); return $p }
function Check($name, $cond, $detail) {
    if ($cond) { [void]$results.Add("PASS  $name  $detail"); L "   [PASS] $name  $detail" }
    else       { [void]$results.Add("FAIL  $name  $detail"); L "   [FAIL] $name  $detail" }
}
function Query($sql) { return (& $mysql -uroot -p1234 -N --default-character-set=utf8mb4 -e $sql 2>$null) }

"=== 全链路验证 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content $log -Encoding UTF8

# ---------- 1. 会员登录 ----------
$login = & curl.exe -s -m 15 -X POST "$base/sso/login" --data-urlencode 'username=test' --data-urlencode 'password=123456' | ConvertFrom-Json
$token = $login.data.token
L "1) 会员登录: code=$($login.code)"
Check '会员登录' ($login.code -eq 200) "token=$($token.Substring(0,16))..."
$H = "Authorization: Bearer $token"

# ---------- 2. 收货地址 ----------
$addrList = & curl.exe -s -m 15 -H $H "$base/member/address/list" | ConvertFrom-Json
$addrId = ($addrList.data | Where-Object { $_.defaultStatus -eq 1 } | Select-Object -First 1).id
if (-not $addrId) { $addrId = @($addrList.data)[0].id }
L "2) 收货地址: 共 $(@($addrList.data).Count) 个, 使用 addressId=$addrId"
Check '收货地址查询' (@($addrList.data).Count -gt 0) "addressId=$addrId"

# ---------- 3. 基准数据 ----------
$detail = & curl.exe -s -m 15 "$base/product/detail/27" | ConvertFrom-Json
$product = $detail.data.product
$skuObj  = $detail.data.skuStockList | Where-Object { $_.id -eq 99 } | Select-Object -First 1
$sku = 99
$stockBefore = (Query "SELECT CONCAT(stock,' ',lock_stock) FROM mall.pms_sku_stock WHERE id=$sku;")
$maxOrderIdBefore = [long](Query "SELECT IFNULL(MAX(id),0) FROM mall.oms_order;")
$cartBefore = & curl.exe -s -m 15 -H $H "$base/cart/list" | ConvertFrom-Json
$cartIdsBefore = @($cartBefore.data | ForEach-Object { $_.id })
L "3) 基准: SKU$sku(stock lock)=$stockBefore 最大订单号=$maxOrderIdBefore 购物车=$($cartIdsBefore.Count)条"
L "   商品: $($product.name) 价格=$($skuObj.price)"

function Add-CartItem {
    $json = @{
        productId       = 27
        productSkuId    = 99
        quantity        = 1
        price           = [double]$skuObj.price
        productName     = $product.name
        productSubTitle = $product.subTitle
        productPic      = $product.pic
        productAttr     = '颜色:黑色;内存:6GB+64GB'
    } | ConvertTo-Json -Compress
    $bf = BodyFile ('cart-' + [guid]::NewGuid().ToString('N') + '.json') $json
    return (& curl.exe -s -m 15 -H $H -X POST "$base/cart/add" -H 'Content-Type: application/json' --data-binary "@$bf" | ConvertFrom-Json)
}

function New-CartItemAndGetIds {
    $before = & curl.exe -s -m 15 -H $H "$base/cart/list" | ConvertFrom-Json
    $beforeIds = @($before.data | ForEach-Object { $_.id })
    $addResp = Add-CartItem
    Start-Sleep -Milliseconds 300
    $after = & curl.exe -s -m 15 -H $H "$base/cart/list" | ConvertFrom-Json
    $newIds = @($after.data | Where-Object { $beforeIds -notcontains $_.id } | ForEach-Object { $_.id })
    return @{ addResp = $addResp; ids = $newIds }
}

function New-Order($cartIds, $addressId) {
    $idsJson = '[' + ($cartIds -join ',') + ']'
    $confirmBody = BodyFile ('confirm-' + [guid]::NewGuid().ToString('N') + '.json') $idsJson
    $confirm = & curl.exe -s -m 20 -H $H -X POST "$base/order/generateConfirmOrder" -H 'Content-Type: application/json' --data-binary "@$confirmBody" | ConvertFrom-Json
    $orderJson = '{"cartIds":' + $idsJson + ',"memberReceiveAddressId":' + $addressId + ',"useIntegration":0,"payType":0}'
    $orderBody = BodyFile ('order-' + [guid]::NewGuid().ToString('N') + '.json') $orderJson
    $orderResp = & curl.exe -s -m 30 -H $H -X POST "$base/order/generateOrder" -H 'Content-Type: application/json' --data-binary "@$orderBody" | ConvertFrom-Json
    return @{ confirm = $confirm; order = $orderResp; cartIds = $cartIds }
}

# ---------- 4-6. 购物车 -> 确认单 -> 生成订单 ----------
$c1 = New-CartItemAndGetIds
L "4) 加购物车: code=$($c1.addResp.code) 新增cartIds=$($c1.ids -join ',')"
Check '加入购物车' ($c1.addResp.code -eq 200 -and $c1.ids.Count -gt 0) "cartIds=$($c1.ids -join ',')"

$o1 = New-Order $c1.ids $addrId
L "5) 确认订单: code=$($o1.confirm.code) 应付=$($o1.confirm.data.calcAmount.payAmount)"
Check '确认订单' ($o1.confirm.code -eq 200) "应付金额=$($o1.confirm.data.calcAmount.payAmount)"
L "6) 生成订单: code=$($o1.order.code) msg=$($o1.order.message)"
$newOrderId = [long](Query "SELECT IFNULL(MAX(id),0) FROM mall.oms_order WHERE id > $maxOrderIdBefore;")
Check '生成订单' ($o1.order.code -eq 200 -and $newOrderId -gt $maxOrderIdBefore) "orderId=$newOrderId"

if ($newOrderId -le $maxOrderIdBefore) {
    L '!! 订单未创建成功，终止后续步骤（避免污染种子数据）'
    L '=== 验证中断 ==='
    exit 1
}

$orderRow = Query "SELECT CONCAT(id,'|',order_sn,'|',status,'|',total_amount,'|',pay_amount,'|',member_id) FROM mall.oms_order WHERE id=$newOrderId;"
$orderSn = ($orderRow -split '\|')[1]
L "   DB订单: $orderRow"
$stockAfterCreate = (Query "SELECT CONCAT(stock,' ',lock_stock) FROM mall.pms_sku_stock WHERE id=$sku;")
L "   SKU$sku 下单后(stock lock)=$stockAfterCreate"
$lockAfterCreate = [int](($stockAfterCreate -split ' ')[1])
$lockBeforeCancelVal = [int](($stockBefore -split ' ')[1])
Check '下单锁定库存' ($lockAfterCreate -eq $lockBeforeCancelVal + 1) "lock_stock: $lockBeforeCancelVal -> $lockAfterCreate"

# ---------- 7. RabbitMQ 延迟队列 ----------
Start-Sleep -Seconds 1
L "7) RabbitMQ 队列（vhost /mall）:"
$queues = & $docker exec mall-rabbitmq rabbitmqctl list_queues -p /mall name messages 2>&1 | Where-Object { $_ -notmatch 'Timeout|Listing' }
$queues | ForEach-Object { L "   $_" }
$ttlLine = $queues | Where-Object { $_ -match 'cancel.ttl' } | Select-Object -First 1
$ttlCount = 0
if ($ttlLine) { $ttlCount = [int](($ttlLine -split "\s+")[-1]) }
Check '延迟取消消息入队' ($ttlCount -ge 1) "mall.order.cancel.ttl messages=$ttlCount"

# ---------- 8. 模拟支付 ----------
$payResp = & curl.exe -s -m 20 -H $H -X POST "$base/order/paySuccess?orderId=$newOrderId&payType=0" | ConvertFrom-Json
L "8) 模拟支付: code=$($payResp.code) msg=$($payResp.message)"
Check '模拟支付' ($payResp.code -eq 200) $payResp.message
Start-Sleep -Seconds 1
$orderAfterPay = Query "SELECT CONCAT(id,'|',order_sn,'|',status,'|',IFNULL(payment_time,'NULL')) FROM mall.oms_order WHERE id=$newOrderId;"
$stockAfterPay = (Query "SELECT CONCAT(stock,' ',lock_stock) FROM mall.pms_sku_stock WHERE id=$sku;")
L "   支付后订单: $orderAfterPay"
L "   支付后库存: $stockAfterPay"
$statusAfterPay = [int](($orderAfterPay -split '\|')[2])
$stockValAfterPay = (($stockAfterPay -split ' ') | ForEach-Object { [int]$_ })
Check '支付后订单状态' ($statusAfterPay -eq 1) "status=1(待发货)"
Check '支付后扣减库存' ($stockValAfterPay[0] -eq ([int](($stockBefore -split ' ')[0])) - 1 -and $stockValAfterPay[1] -eq $lockBeforeCancelVal) "stock,lock=$($stockAfterPay)"

# ---------- 9. 再下一单并取消 ----------
$c2 = New-CartItemAndGetIds
$o2 = New-Order $c2.ids $addrId
$newOrderId2 = [long](Query "SELECT IFNULL(MAX(id),0) FROM mall.oms_order;")
L "9) 第二单: code=$($o2.order.code) orderId=$newOrderId2"
if ($o2.order.code -eq 200 -and $newOrderId2 -gt $newOrderId) {
    $lockBeforeCancel2 = (Query "SELECT CONCAT(stock,' ',lock_stock) FROM mall.pms_sku_stock WHERE id=$sku;")
    L "   取消前库存: $lockBeforeCancel2"
    $cancelResp = & curl.exe -s -m 20 -H $H -X POST "$base/order/cancelUserOrder?orderId=$newOrderId2" | ConvertFrom-Json
    L "   取消订单: code=$($cancelResp.code) msg=$($cancelResp.message)"
    Start-Sleep -Seconds 1
    $orderAfterCancel = Query "SELECT CONCAT(id,'|',status) FROM mall.oms_order WHERE id=$newOrderId2;"
    $stockAfterCancel = (Query "SELECT CONCAT(stock,' ',lock_stock) FROM mall.pms_sku_stock WHERE id=$sku;")
    L "   取消后订单: $orderAfterCancel  取消后库存: $stockAfterCancel"
    $statusAfterCancel = [int](($orderAfterCancel -split '\|')[1])
    $lockAfterCancel = [int](($stockAfterCancel -split ' ')[1])
    Check '取消订单' ($cancelResp.code -eq 200 -and $statusAfterCancel -eq 4) "status=$statusAfterCancel(4=已关闭)"
    Check '取消后释放锁定库存' ($lockAfterCancel -eq $lockBeforeCancelVal) "lock_stock=$lockAfterCancel"
} else {
    Check '第二单创建' $false "code=$($o2.order.code) msg=$($o2.order.message)"
}

# ---------- 10. 汇总 ----------
$fail = @($results | Where-Object { $_ -like 'FAIL*' })
L ''
L "=== 验证汇总: 通过 $($results.Count - $fail.Count)/$($results.Count) ==="
$results | ForEach-Object { L "  $_" }
if ($fail.Count -eq 0) { L 'RESULT=PASS' } else { L 'RESULT=FAIL' }
