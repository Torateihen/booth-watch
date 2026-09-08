<#
  BOOTH ショップ更新監視 → Discord 通知
  公開ページの JSON を定期的に読んで、前回との差分を Discord の Webhook に投げる。
  非公式エンドポイント（https://booth.pm/ja/items/<id>.json）を使用。
#>
[CmdletBinding()]
param(
    [string] $Shop = 'bbeyemtkw',
    [string] $WebhookUrl,
    [switch] $Init,
    [switch] $NotifyDescription,
    [switch] $DryRun,
    [string] $StateFile = (Join-Path $PSScriptRoot 'state.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

# ---- Webhook URL ----
# 優先順位: 引数 > 環境変数 BOOTH_WEBHOOK（GitHub Actions用） > webhook.txt（ローカル用）
if (-not $WebhookUrl) { $WebhookUrl = $env:BOOTH_WEBHOOK }
if (-not $WebhookUrl) {
    $wf = Join-Path $PSScriptRoot 'webhook.txt'
    if (Test-Path $wf) { $WebhookUrl = (Get-Content $wf -Raw -Encoding UTF8) }
}
if ($WebhookUrl) { $WebhookUrl = $WebhookUrl.Trim() }
if ($WebhookUrl -and $WebhookUrl -notmatch '^https://(discord|discordapp)\.com/api/webhooks/') {
    throw "Webhook URL の形が違います。https://discord.com/api/webhooks/... で始まる必要があります。"
}

function Get-Text([string]$Url) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UserAgent $UA -Headers @{ 'Accept-Language' = 'ja,en;q=0.9' } -UseBasicParsing
            # PowerShell 5.1 は文字コード判定を誤るのでバイト列から読む。
            # PowerShell 7 では RawContentStream が空のことがあるので Content を使う。
            if ($r.RawContentStream -and $r.RawContentStream.Length -gt 0) {
                return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            }
            return [string]$r.Content
        }
        catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds 3
        }
    }
}

function Get-Hash([string]$Text) {
    if ($null -eq $Text) { $Text = '' }
    $sha = [Security.Cryptography.SHA1]::Create()
    $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    ($b | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-ShopItemIds([string]$Subdomain) {
    $html = Get-Text "https://$Subdomain.booth.pm/items"
    $ids = [regex]::Matches($html, '/items/(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
    , ($ids | Sort-Object -Unique)
}

# 商品説明の段落（見出し＋本文）は JSON に載らないので HTML から拾う
function Get-BodyHash([int]$Id) {
    try {
        $html = Get-Text "https://booth.pm/ja/items/$Id"
        $opt = [Text.RegularExpressions.RegexOptions]::Singleline
        $sb = New-Object Text.StringBuilder
        foreach ($m in [regex]::Matches($html, '<section class="shop__text">(.*?)</section>', $opt)) {
            [void]$sb.Append($m.Groups[1].Value)
        }
        return Get-Hash $sb.ToString()
    }
    catch { return '' }
}

function Get-Fingerprint([int]$Id) {
    $item = Get-Text "https://booth.pm/ja/items/$Id.json" | ConvertFrom-Json

    $fileNames = @()
    foreach ($v in $item.variations) {
        $files = @($v.downloadable.no_musics) + @($v.downloadable.musics) | Where-Object { $_ }
        foreach ($f in $files) { $fileNames += $f.name }
    }
    $filesJoined = ($fileNames | Sort-Object) -join ' | '

    $ver = ''
    $vm = [regex]::Match($filesJoined, 'Ver\.?\s*([0-9]+(?:\.[0-9]+)+)', 'IgnoreCase')
    if ($vm.Success) { $ver = $vm.Groups[1].Value }

    $img = ''
    if (@($item.images).Count -gt 0) { $img = $item.images[0].original }

    $bodyHash = ''
    if ($NotifyDescription) { $bodyHash = Get-BodyHash $Id }

    [pscustomobject]@{
        id        = [int]$item.id
        name      = [string]$item.name
        url       = [string]$item.url
        price     = [string]$item.price
        image     = $img
        files     = $filesJoined
        version   = $ver
        soldOut   = [bool]$item.is_sold_out
        endOfSale = [bool]$item.is_end_of_sale
        descHash  = Get-Hash ([string]$item.description)
        bodyHash  = $bodyHash
    }
}

function Send-Discord($Embed) {
    if ($DryRun -or -not $WebhookUrl) {
        Write-Host ("  [DryRun] {0}" -f $Embed.title) -ForegroundColor DarkGray
        if ($Embed.description) { Write-Host ("           {0}" -f $Embed.description) -ForegroundColor DarkGray }
        return
    }
    $payload = @{
        username = 'BOOTH更新おしらせ'
        embeds   = @($Embed)
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes -ContentType 'application/json' | Out-Null
            Start-Sleep -Milliseconds 800
            return
        }
        catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function New-Embed([string]$Title, [string]$Desc, [int]$Color, $Fp) {
    $e = @{
        title       = $Title
        url         = $Fp.url
        description = $Desc
        color       = $Color
        timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        footer      = @{ text = "BOOTH / $Shop" }
    }
    if ($Fp.image) { $e['thumbnail'] = @{ url = $Fp.image } }
    return $e
}

# ---- 前回の状態 ----
$old = @{}
$firstRun = $true
if (Test-Path $StateFile) {
    $firstRun = $false
    $raw = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $raw.PSObject.Properties) { $old[$p.Name] = $p.Value }
}

Write-Host ("ショップ {0} を確認中..." -f $Shop) -ForegroundColor Cyan
$ids = Get-ShopItemIds $Shop
Write-Host ("  商品 {0}件" -f $ids.Count)

$new = @{}
$changes = 0

foreach ($id in $ids) {
    try { $fp = Get-Fingerprint $id }
    catch { Write-Host ("  [{0}] 取得失敗: {1}" -f $id, $_.Exception.Message) -ForegroundColor Red; continue }

    $key = [string]$id
    $new[$key] = $fp

    if ($firstRun -or $Init) { continue }

    $prev = $old[$key]

    # ---- 新商品 ----
    if ($null -eq $prev) {
        Write-Host ("  + 新商品: {0}" -f $fp.name) -ForegroundColor Green
        $d = "**新しく公開されました。**"
        if ($fp.version) { $d += "`nバージョン: ``{0}``" -f $fp.version }
        $d += "`n価格: {0}" -f $fp.price
        Send-Discord (New-Embed ("🆕 " + $fp.name) $d 3066993 $fp)
        $changes++
        continue
    }

    $lines = @()

    # ---- バージョンアップ / 配布ファイルの差し替え ----
    if ($prev.files -ne $fp.files) {
        if ($prev.version -and $fp.version -and $prev.version -ne $fp.version) {
            $lines += ("バージョン: ``{0}`` → **``{1}``**" -f $prev.version, $fp.version)
        }
        else {
            $lines += "配布ファイルが差し替えられました。"
            if ($fp.files) { $lines += ("``{0}``" -f $fp.files) }
        }
    }

    # ---- 価格 ----
    if ($prev.price -ne $fp.price) {
        $lines += ("価格: {0} → **{1}**" -f $prev.price, $fp.price)
    }

    # ---- 販売状態 ----
    if ($prev.soldOut -ne $fp.soldOut) {
        if ($fp.soldOut) { $lines += "**売り切れ**になりました。" } else { $lines += "在庫が戻りました。" }
    }
    if ($prev.endOfSale -ne $fp.endOfSale) {
        if ($fp.endOfSale) { $lines += "**販売終了**になりました。" } else { $lines += "販売を再開しました。" }
    }

    # ---- 商品名 ----
    if ($prev.name -ne $fp.name) {
        $lines += ("商品名が変わりました: {0}" -f $prev.name)
    }

    # ---- 説明文（-NotifyDescription のときだけ） ----
    if ($NotifyDescription) {
        if ($prev.descHash -ne $fp.descHash -or ($fp.bodyHash -and $prev.bodyHash -ne $fp.bodyHash)) {
            $lines += "商品説明が更新されました。"
        }
    }

    if ($lines.Count -gt 0) {
        Write-Host ("  ~ 更新: {0}" -f $fp.name) -ForegroundColor Yellow
        Send-Discord (New-Embed ("🔄 " + $fp.name) ($lines -join "`n") 15844367 $fp)
        $changes++
    }
}

# ---- 消えた商品 ----
if (-not $firstRun -and -not $Init) {
    foreach ($k in $old.Keys) {
        if (-not $new.ContainsKey($k)) {
            $p = $old[$k]
            Write-Host ("  - 非公開: {0}" -f $p.name) -ForegroundColor DarkYellow
            Send-Discord (New-Embed ("⚫ " + $p.name) "ショップの一覧から消えました（非公開・販売終了など）。" 9807270 $p)
            $changes++
        }
    }
}

# ---- 保存 ----
$dir = Split-Path $StateFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$outJson = ConvertTo-Json -InputObject $new -Depth 10
[IO.File]::WriteAllText($StateFile, $outJson, (New-Object Text.UTF8Encoding $false))

if ($firstRun -or $Init) {
    Write-Host ("`n初回のため通知はせず、現在の状態を記録しました: {0}" -f $StateFile) -ForegroundColor Green
    Write-Host "次回以降、変化があったぶんだけ通知します。"
}
else {
    Write-Host ("`n通知 {0}件" -f $changes) -ForegroundColor Green
}
