param(
  [string]$ProjectDir = ".\todoapi-v00",
  [ValidateSet("net9.0","net8.0")]
  [string]$TargetFramework = "net9.0",
  [string]$OpenApiVersion = "9.0.8",
  [string]$SwashbuckleVersion = "9.0.3"
)

function Get-Or-Create-Element([System.Xml.XmlDocument]$doc, [System.Xml.XmlNode]$parent, [string]$name) {
  $node = $parent.SelectSingleNode($name)
  if (-not $node) {
    $node = $doc.CreateElement($name)
    $parent.AppendChild($node) | Out-Null
  }
  return $node
}

function Update-Csproj([string]$csprojPath) {
  Write-Host "Updating $csprojPath" -ForegroundColor Cyan
  [xml]$xml = Get-Content $csprojPath

  # Assicura almeno un PropertyGroup
  $pgs = $xml.Project.PropertyGroup
  if (-not $pgs) {
    $pg = $xml.CreateElement("PropertyGroup")
    $xml.Project.AppendChild($pg) | Out-Null
  }
  # Usa il primo PropertyGroup
  $pg = @($xml.Project.PropertyGroup)[0]

  # TargetFramework
  $tfNode = $pg.SelectSingleNode("TargetFramework")
  if (-not $tfNode) {
    $tfNode = $xml.CreateElement("TargetFramework")
    $pg.AppendChild($tfNode) | Out-Null
  }
  $tfNode.InnerText = $TargetFramework

  # Nullable / ImplicitUsings
  $nullable = Get-Or-Create-Element $xml $pg "Nullable"
  $nullable.InnerText = "enable"
  $implicit = Get-Or-Create-Element $xml $pg "ImplicitUsings"
  $implicit.InnerText = "enable"

  # Doc xml (facoltativo)
  $docfile = Get-Or-Create-Element $xml $pg "GenerateDocumentationFile"
  $docfile.InnerText = "true"
  $nowarn = Get-Or-Create-Element $xml $pg "NoWarn"
  if ($nowarn.InnerText -notmatch "\b1591\b") {
    $nowarn.InnerText = ($nowarn.InnerText.Trim() + ";1591").TrimStart(";")
  }

  # ItemGroup per pacchetti
  $itemGroup = ($xml.Project.ItemGroup | Where-Object { $_.SelectNodes("PackageReference").Count -gt 0 } | Select-Object -First 1)
  if (-not $itemGroup) {
    $itemGroup = $xml.CreateElement("ItemGroup")
    $xml.Project.AppendChild($itemGroup) | Out-Null
  }

  function Upsert-Package([System.Xml.XmlDocument]$doc, $ig, [string]$id, [string]$ver) {
    $pkg = $ig.SelectNodes("PackageReference") | Where-Object { $_.GetAttribute("Include") -eq $id } | Select-Object -First 1
    if (-not $pkg) {
      $pkg = $doc.CreateElement("PackageReference")
      $pkg.SetAttribute("Include", $id)
      $pkg.SetAttribute("Version", $ver)
      $ig.AppendChild($pkg) | Out-Null
    } else {
      $pkg.SetAttribute("Version", $ver)
    }
  }

  Upsert-Package $xml $itemGroup "Microsoft.AspNetCore.OpenApi" $OpenApiVersion
  Upsert-Package $xml $itemGroup "Swashbuckle.AspNetCore" $SwashbuckleVersion

  Copy-Item $csprojPath "$csprojPath.bak" -Force
  $xml.Save($csprojPath)
}

function Update-ProgramCs([string]$programPath) {
  if (-not (Test-Path $programPath)) { Write-Warning "Program.cs non trovato: salto patch"; return }
  Write-Host "Patching $programPath" -ForegroundColor Cyan
  $txt = Get-Content $programPath -Raw

  if ($txt -notmatch "using\s+Microsoft\.AspNetCore\.OpenApi;") {
    $txt = "using Microsoft.AspNetCore.OpenApi;`r`n" + $txt
  }

  if ($txt -notmatch "AddOpenApi\(") {
    # Inserisci dopo AddSwaggerGen oppure subito dopo la creazione del builder
    if ($txt -match "AddSwaggerGen\(\)\s*;") {
      $txt = $txt -replace "AddSwaggerGen\(\)\s*;", "AddSwaggerGen();`r`nbuilder.Services.AddOpenApi();"
    } elseif ($txt -match "var\s+builder\s*=\s*WebApplication\.CreateBuilder\(.*?\)\s*;") {
      $txt = $txt -replace "(var\s+builder\s*=\s*WebApplication\.CreateBuilder\(.*?\)\s*;)", "`$1`r`nbuilder.Services.AddOpenApi();"
    } else {
      # fallback: aggiungi subito dopo la prima riga
      $lines = $txt -split "`r`n"
      $txt = ($lines[0..0] + "builder.Services.AddOpenApi();" + $lines[1..($lines.Length-1)]) -join "`r`n"
    }
  }

  if ($txt -match "if\s*\(\s*app\.Environment\.IsDevelopment\(\)\s*\)\s*{") {
    $block = [regex]::Match($txt, "if\s*\(\s*app\.Environment\.IsDevelopment\(\)\s*\)\s*{.*?}", "Singleline").Value
    if ($block -notmatch "MapOpenApi\(") { $block = $block -replace "{", "{`r`n    app.MapOpenApi();" }
    if ($block -notmatch "UseSwagger\(") { $block = $block -replace "{", "{`r`n    app.UseSwagger();" }
    if ($block -notmatch "UseSwaggerUI\(") { $block = $block -replace "{", "{`r`n    app.UseSwaggerUI();" }
    $txt = $txt -replace "if\s*\(\s*app\.Environment\.IsDevelopment\(\)\s*\)\s*{.*?}", [System.Text.RegularExpressions.Regex]::Escape($block).Replace("\","")
  } else {
    $txt = $txt -replace "(var\s+app\s*=\s*builder\.Build\(\)\s*;)", "`$1`r`nif (app.Environment.IsDevelopment()) {`r`n    app.MapOpenApi();`r`n    app.UseSwagger();`r`n    app.UseSwaggerUI();`r`n}`r`n"
  }

  Copy-Item $programPath "$programPath.bak" -Force
  Set-Content $programPath $txt -Encoding UTF8
}

# MAIN
$proj = Get-ChildItem -Path $ProjectDir -Filter *.csproj -File -Recurse | Select-Object -First 1
if (-not $proj) { throw "Nessun .csproj trovato in $ProjectDir" }
Update-Csproj $proj.FullName

$program = Get-ChildItem -Path $ProjectDir -Filter Program.cs -File -Recurse | Select-Object -First 1
Update-ProgramCs $program.FullName

Write-Host "`nOK. Ora:" -ForegroundColor Green
Write-Host "dotnet restore `"$($proj.DirectoryName)`""
Write-Host "dotnet build   `"$($proj.DirectoryName)`" -c Release"
Write-Host "dotnet run     --project `"$($proj.FullName)`""
