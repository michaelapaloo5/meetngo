# Fetches the driver-approvals page from the edge function and writes it out as
# a static index.html, ready to upload to a normal web host.
#
# ## Why this exists
#
# The page is generated from `supabase/functions/admin-drivers/staff_page.ts`,
# which is a TypeScript template rather than a checked-in HTML file. Keeping the
# generator as the source of truth means the decline reasons, the document
# labels and the required-document list come from the same constants the server
# enforces, and cannot drift.
#
# ## Why it has to be hosted somewhere that is not Supabase
#
# Supabase will not serve this page as HTML, and the evidence is in the code
# comments on the two bugs it caused:
#
#   * The edge function's response comes back `Content-Type: text/plain` no matter
#     how the function sets it. Tried `Content-Type`, `content-type`, both at
#     once, and via a `Headers` object. The gateway rewrites it and Cloudflare
#     then adds `X-Content-Type-Options: nosniff` and
#     `Content-Security-Policy: default-src 'none'; sandbox` on top, so a
#     browser displays the markup as source instead of rendering it.
#   * A public Storage bucket serves the same object as `text/plain` with
#     `x-robots-tag: none`, even though the stored mimetype is correctly
#     `text/html; charset=utf-8`. A signed URL is worse: it comes back
#     `scope: download`.
#
# That is deliberate hardening so a public bucket cannot be used to host
# indexable pages. Ordinary shared hosting has no such rule, which is why this
# script exists.
#
# The lesson, which cost the page everything once: **verifying a web page with
# curl proves nothing about whether it renders.** Every check that said this
# page worked was reading the body, and the body was always right.
#
# Usage:
#   pwsh -File toolchain\build-admin-page.ps1 -OutDir C:\somewhere\htdocs
#
# -OutDir defaults to `admin-page\` in the repository, which is gitignored,
# because the artifact is generated and the generator is committed.

param(
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'admin-page')
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root 'toolchain\supabase-admin.env'
if (-not (Test-Path $envFile)) { throw "no $envFile" }
$vars = @{}
Get-Content $envFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $vars[$matches[1]] = $matches[2] }
}
$ref = $vars['SUPABASE_PROJECT_REF']
if ([string]::IsNullOrWhiteSpace($ref)) { throw 'no SUPABASE_PROJECT_REF in the token file' }

$source = "https://$ref.supabase.co/functions/v1/admin-drivers"
$target = Join-Path $OutDir 'index.html'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# `Accept: text/html` so that if the hosting ever changes the response is still
# the page rather than a download, and so the failure is obvious here rather than
# on a phone.
#
# Joined into one string before anything is tested. curl writes a line per line
# and PowerShell hands back an ARRAY, so `-notmatch` against the array answers
# "is there a line that does not look like a doctype" -- which is nearly all of
# them, on a perfectly good page. That is what the first version of this script
# did, and it failed on a response that was correct.
Write-Output "fetching $source"
$lines = & curl.exe -s --fail -H 'Accept: text/html' $source
$html = ($lines -join "`n")
if ([string]::IsNullOrWhiteSpace($html)) { throw 'the function returned nothing' }
if ($html -notmatch '<!doctype html>') {
  throw 'the function did not return a page -- it may be refusing the request'
}

# The checks below are the ones that would have caught the original problem. They
# read the file that is about to be uploaded rather than trusting that the
# function is still deployed, because the failure mode here is a page that is
# subtly not a page and nobody looks at it until an employee does.
$problems = @()
if ($html -match 'eyJ[A-Za-z0-9_-]{20,}') { $problems += 'it contains something shaped like a JWT' }
if ($html -match 'service_role') { $problems += 'it mentions the service role key' }
if ($html -notmatch 'const API =') { $problems += 'it has no API constant, so its fetches will not work off this host' }
if ($html -notmatch 'staffsignin') { $problems += 'it has no sign-in call' }
if ($html -notmatch 'id="yesBtn"') { $problems += 'it has no Approve button' }
if ($html -notmatch 'id="noBtn"') { $problems += 'it has no Decline button' }
if ($html -match '\$\{') { $problems += 'an unsubstituted template placeholder reached the output' }
if ($problems.Count -gt 0) {
  foreach ($p in $problems) { Write-Output "  PROBLEM: $p" }
  throw 'the generated page failed its own checks -- not writing it'
}

[System.IO.File]::WriteAllText($target, $html, (New-Object System.Text.UTF8Encoding($false)))
$kb = [math]::Round((Get-Item $target).Length / 1KB, 1)
Write-Output "wrote $target ($kb KB)"

# Then the check that matters, on the file that was just written rather than on
# the generator that produced it. `deno run --allow-net --allow-read --allow-env
# toolchain\verify-admin-page.ts <path>` executes the page's own script against a
# DOM stub and asks whether opening a driver produces an Approve button.
#
# A separate step on purpose. The page was once generated correctly, deployed
# correctly, type-checked, passed every string assertion in the suite, and had no
# Approve button on it -- because the function that builds the bar was only ever
# called from the error path inside `send`, and nobody could reach a failed save
# without a button to press first. Reading the HTML cannot find that. Running it
# can.
$verifier = Join-Path $root 'toolchain\verify-admin-page.ts'
if (Test-Path $verifier) {
  $deno = Get-Command deno -ErrorAction SilentlyContinue
  if ($deno) {
    Write-Output ''
    Write-Output 'running the page, because reading it is not enough:'
    & deno run --allow-net --allow-env --allow-read $verifier $target
    if ($LASTEXITCODE -ne 0) {
      throw 'the page does not work when it is run -- do not upload it'
    }
  } else {
    Write-Output '  (deno not on PATH; skipped the run-the-page check)'
  }
}

Write-Output ''
Write-Output 'Upload that ONE file as index.html at the root of your web space.'
Write-Output 'Nothing else is needed: no PHP, no build step, no database.'
