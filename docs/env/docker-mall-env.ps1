# 一键准备 mall 本地中间件（Docker 容器版）
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\docker-mall-env.ps1            # 只起 mongo + rabbitmq（W0 必需）
#   powershell -ExecutionPolicy Bypass -File .\docker-mall-env.ps1 -WithSearch # 额外起 Elasticsearch（W2/W4 用）
#   powershell -ExecutionPolicy Bypass -File .\docker-mall-env.ps1 -WithMinio  # 额外起 MinIO（文件上传用）
#
# 说明：本机已有原生 MySQL(3306) 与 Memurai Redis(6379)，所以容器只起 mongo/rabbitmq/es/minio，
#       不再起 mysql/redis，避免端口冲突。

param(
    [switch]$WithSearch,
    [switch]$WithMinio
)

$ErrorActionPreference = 'Stop'
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
if (-not (Test-Path $docker)) { $docker = 'docker' }

Write-Host '== 检查 Docker 引擎 ==' -ForegroundColor Cyan
& $docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker 引擎未启动：请先打开 Docker Desktop，等鲸鱼图标变绿后重试' }
& $docker version --format 'Docker 引擎 {{.Server.Version}}'

function Ensure-Container {
    param([string]$Name, [string]$Image, [string[]]$Ports, [string[]]$Envs, [string[]]$Volumes, [string[]]$Cmd, [string]$HealthUrl)
    $exists = & $docker ps -a --filter "name=^/$Name$" --format '{{.Names}}'
    if ($exists) {
        $running = & $docker ps --filter "name=^/$Name$" --format '{{.Names}}'
        if (-not $running) { & $docker start $Name | Out-Null }
        Write-Host "[OK] $Name 已存在并运行" -ForegroundColor Green
        return
    }
    Write-Host "== 拉取镜像并创建 $Name ($Image) ==" -ForegroundColor Cyan
    $args = @('run','-d','--name',$Name,'--restart=unless-stopped')
    foreach ($p in $Ports)   { $args += @('-p', $p) }
    foreach ($e in $Envs)    { $args += @('-e', $e) }
    foreach ($v in $Volumes) { $args += @('-v', $v) }
    $args += $Image
    if ($Cmd) { $args += $Cmd }
    & $docker @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$Name 启动失败" }
    Write-Host "[OK] $Name 已启动" -ForegroundColor Green
}

# 1) MongoDB 4（mall-portal 必需）
Ensure-Container -Name 'mall-mongo' -Image 'mongo:4' `
    -Ports @('27017:27017') -Volumes @('mall-mongo-data:/data/db')

# 2) RabbitMQ 3.9 + 管理台（mall-portal 下单/超时取消必需）
Ensure-Container -Name 'mall-rabbitmq' -Image 'rabbitmq:3.9.11-management' `
    -Ports @('5672:5672','15672:15672') -Volumes @('mall-rabbitmq-data:/var/lib/rabbitmq')

# 2.1) RabbitMQ 初始化：mall 项目需要 vhost=/mall、用户=mall/mall（否则 portal 启动报 ACCESS_REFUSED）
Write-Host '== 初始化 RabbitMQ 用户/vhost (mall/mall @ /mall) ==' -ForegroundColor Cyan
$rabbitReady = $false
for ($i = 0; $i -lt 30; $i++) {
    & $docker exec mall-rabbitmq rabbitmqctl await_startup *> $null
    if ($LASTEXITCODE -eq 0) { $rabbitReady = $true; break }
    Start-Sleep -Seconds 2
}
if ($rabbitReady) {
    # 已存在用户/vhost 时命令会返回非 0，这里逐个 try 掉，保证脚本幂等可重复执行
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $users = & $docker exec mall-rabbitmq rabbitmqctl list_users 2>$null | Out-String
        if ($users -notmatch '(?m)^mall\s') { & $docker exec mall-rabbitmq rabbitmqctl add_user mall mall 2>$null | Out-Null }
        $vhosts = & $docker exec mall-rabbitmq rabbitmqctl list_vhosts 2>$null | Out-String
        if ($vhosts -notmatch '(?m)^/mall\s*$') { & $docker exec mall-rabbitmq rabbitmqctl add_vhost /mall 2>$null | Out-Null }
        & $docker exec mall-rabbitmq rabbitmqctl set_permissions -p /mall mall ".*" ".*" ".*" 2>$null | Out-Null
        & $docker exec mall-rabbitmq rabbitmqctl set_user_tags mall administrator 2>$null | Out-Null
        Write-Host '[OK] RabbitMQ 用户 mall / vhost /mall 已就绪' -ForegroundColor Green
    } catch {
        Write-Host '[WARN] RabbitMQ 初始化出现异常（可能已初始化过，可忽略）' -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevEap
    }
} else {
    Write-Host '[WARN] RabbitMQ 尚未就绪，初始化可能未完成，请稍后重试本脚本' -ForegroundColor Yellow
}

# 3) Elasticsearch 8.18.8 + IK 分词插件（可选；mall-search 需要，版本必须与 Spring Data ES 5.5 / elasticsearch-java 8.18.8 匹配）
if ($WithSearch) {
    $esImage = 'elasticsearch:8.18.8'
    # 3.1 确保 IK 分词插件目录（插件版本必须严格等于 ES 版本 8.18.8）
    $ikDir = 'D:\MyProject_Newer\_docker\es-plugins\analysis-ik'
    if (-not (Test-Path (Join-Path $ikDir 'plugin-descriptor.properties'))) {
        Write-Host '== 下载 IK 分词插件（8.18.8）==' -ForegroundColor Cyan
        $ikZip = 'D:\MyProject_Newer\_downloads\elasticsearch-analysis-ik-8.18.8.zip'
        New-Item -ItemType Directory -Force -Path (Split-Path $ikZip) | Out-Null
        & curl.exe -sS -4 -L -o $ikZip 'https://release.infinilabs.com/analysis-ik/stable/elasticsearch-analysis-ik-8.18.8.zip'
        New-Item -ItemType Directory -Force -Path $ikDir | Out-Null
        Expand-Archive -Path $ikZip -DestinationPath $ikDir -Force
    }
    # 3.2 旧版本 ES 容器/数据卷不兼容，自动重建
    $prevImage = & $docker inspect --format '{{.Config.Image}}' mall-es 2>$null
    if ($LASTEXITCODE -eq 0 -and $prevImage -and $prevImage -ne $esImage) {
        Write-Host "== 发现旧 ES 容器（$prevImage），删除并重建为 $esImage ==" -ForegroundColor Yellow
        & $docker rm -f mall-es *> $null
        & $docker volume rm mall-es-data *> $null
    }
    Ensure-Container -Name 'mall-es' -Image $esImage `
        -Ports @('9200:9200','9300:9300') `
        -Envs @('discovery.type=single-node','ES_JAVA_OPTS=-Xms512m -Xmx512m','xpack.security.enabled=false','xpack.security.enrollment.enabled=false') `
        -Volumes @('mall-es-data:/usr/share/elasticsearch/data', "${ikDir}:/usr/share/elasticsearch/plugins/analysis-ik")
}

# 4) MinIO（可选，文件上传）
if ($WithMinio) {
    Ensure-Container -Name 'mall-minio' -Image 'minio/minio' `
        -Ports @('9000:9000','9001:9001') `
        -Envs @('MINIO_ROOT_USER=minioadmin','MINIO_ROOT_PASSWORD=minioadmin') `
        -Volumes @('mall-minio-data:/data') `
        -Cmd @('server','/data','--console-address',':9001')
}

Start-Sleep -Seconds 3
Write-Host ''
Write-Host '== 容器状态 ==' -ForegroundColor Cyan
& $docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'
Write-Host ''
Write-Host 'MongoDB      : localhost:27017'
Write-Host 'RabbitMQ     : localhost:5672（管理台 http://localhost:15672，账号 guest/guest）'
if ($WithSearch) { Write-Host 'Elasticsearch: http://localhost:9200' }
if ($WithMinio)  { Write-Host 'MinIO        : http://localhost:9000 / 控制台 http://localhost:9001（minioadmin/minioadmin）' }
Write-Host ''
Write-Host '下一步：启动 mall-portal（IDEA 运行配置 MallPortalApplication，或命令行 8085）' -ForegroundColor Yellow
