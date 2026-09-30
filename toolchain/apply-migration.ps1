# Applies a migration to Supabase through the Management API.
#
# The `/database/query` endpoint takes ONE statement per call, and a migration is
# not one statement. So this splits the file first, and splitting SQL correctly is
# the whole job. It has been got wrong twice, both times in ways that produced an
# error pointing at the wrong thing:
#
#   * Splitting on `;` alone broke the three `$$`-quoted function bodies, because
#     a plpgsql body is full of semicolons that are not the end of anything.
#   * Then handling `$$` but not `--` split on a semicolon inside the header
#     comment and posted the middle of an English paragraph to the server, which
#     came back as `syntax error at or near "it"`.
#
# So this tracks both: a dollar-quoted body, and a line comment. Everything else
# is a plain character.
#
# Usage:
#   pwsh -File toolchain\apply-migration.ps1 -Path supabase\migrations\FILE.sql
#
# The PAT comes from toolchain/supabase-admin.env, which is gitignored. It is not
# a command-line argument so it cannot end up in a shell history.

param(
  [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'

# The repository root. This file lives in `toolchain/`, so one level up from here
# is it. Two, which is what this said first, is `C:\Windows\System32` and the
# error that produced -- "no such token file" -- pointed at a path nobody has ever
# heard of.
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root 'toolchain\supabase-admin.env'
if (-not (Test-Path $envFile)) {
  throw "no $envFile -- the token file is missing"
}
$vars = @{}
Get-Content $envFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $vars[$matches[1]] = $matches[2] }
}
$token = $vars['SUPABASE_ADMIN_TOKEN']
$ref = $vars['SUPABASE_PROJECT_REF']
if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($ref)) {
  throw 'the token file does not contain SUPABASE_ADMIN_TOKEN and SUPABASE_PROJECT_REF'
}

# --- split into statements, dollar-quote and comment aware -------------------

$text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
$newline = [char]10
$dollar = '$' + '$'

$statements = New-Object System.Collections.Generic.List[string]
$current = New-Object System.Text.StringBuilder
$inDollar = $false
$inString = $false
$i = 0

while ($i -lt $text.Length) {
  $ch = $text[$i]

  # A `--` line comment. Copied through to the end of the line and then skipped,
  # because a comment is full of semicolons that end sentences rather than
  # statements.
  if ((-not $inDollar) -and (-not $inString) -and $ch -eq '-' -and ($i + 1) -lt $text.Length -and $text[$i + 1] -eq '-') {
    while ($i -lt $text.Length -and $text[$i] -ne $newline) {
      [void]$current.Append($text[$i])
      $i++
    }
    continue
  }

  # A dollar-quoted block: `$$`, or a tagged one like `$fn$`.
  #
  # The tag matters because this file uses `$fn$` and the first version of this
  # splitter only recognised `$$`. It therefore cut every function body at the
  # first `;` inside it and the server answered "unterminated dollar-quoted
  # string" -- which is a complaint about the splitter, delivered as if it were
  # about the SQL.
  #
  # A tag is `$` plus an identifier (letters, digits, underscore) plus `$`, and
  # it must not be preceded by a word character or it is a `$1` placeholder.
  if ((-not $inString) -and $ch -eq '$') {
    $j = $i + 1
    while ($j -lt $text.Length -and ($text[$j] -match '[A-Za-z0-9_]')) { $j++ }
    if ($j -lt $text.Length -and $text[$j] -eq '$') {
      # Not a positional parameter like $1, which has no closing `$`.
      $prevIsWord = $i -gt 0 -and ($text[$i - 1] -match '[A-Za-z0-9_]')
      if (-not $prevIsWord) {
        $inDollar = -not $inDollar
        [void]$current.Append($text.Substring($i, $j - $i + 1))
        $i = $j + 1
        continue
      }
    }
  }

  # A single-quoted string. A `;` inside one is text, and the third way this
  # splitter was wrong was splitting `comment on table ... is '...; ...'` in
  # two and sending half a sentence to the server.
  #
  # `''` is an escaped quote rather than a close-then-open, which is the same
  # statement either way but two fewer places for the flag to be wrong.
  if ((-not $inDollar) -and $ch -eq "'") {
    $isEscaped = ($i + 1) -lt $text.Length -and $text[$i + 1] -eq "'"
    if ($isEscaped) {
      [void]$current.Append("''")
      $i += 2
      continue
    }
    $inString = -not $inString
    [void]$current.Append($ch)
    $i++
    continue
  }

  if ($ch -eq ';' -and (-not $inDollar) -and (-not $inString)) {
    $piece = $current.ToString().Trim()
    if ($piece -ne '') { $statements.Add($piece) }
    [void]$current.Clear()
    $i++
    continue
  }

  [void]$current.Append($ch)
  $i++
}

$tail = $current.ToString().Trim()
if ($tail -ne '') { $statements.Add($tail) }

if ($inDollar) {
  throw 'the file ends inside a $$ block, so it is truncated'
}
if ($inString) {
  throw 'the file ends inside a quoted string, so it is truncated'
}

Write-Output ('split {0} into {1} statements' -f (Split-Path -Leaf $Path), $statements.Count)

# --- send them ---------------------------------------------------------------

$uri = "https://api.supabase.com/v1/projects/$ref/database/query"
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$n = 0
foreach ($statement in $statements) {
  $n++
  # A first line for the error message, so a failure names the statement rather
  # than a line number in a file the reader may not have open. Comment-only
  # fragments are reported as such, because "ok -- <a sentence>" reads like it
  # did something.
  $preview = ($statement -split "`n")[0].Trim()
  $isComment = $preview.StartsWith('--')
  if ($isComment) {
    $preview = 'comment'
  } elseif ($preview.Length -gt 58) {
    $preview = $preview.Substring(0, 58)
  }

  $body = @{ query = $statement } | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body | Out-Null
    Write-Output ('  [{0}/{1}] ok  {2}' -f $n, $statements.Count, $preview)
  } catch {
    $detail = $_.ErrorDetails.Message
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
    Write-Output ('  [{0}/{1}] FAILED  {2}' -f $n, $statements.Count, $preview)
    throw $detail
  }
}

Write-Output 'MIGRATION APPLIED'
