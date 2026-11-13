<#
.SYNOPSIS
    One-time computer setup for building apps with the App Bootstrap Starter.

.DESCRIPTION
    Installs Git, Visual Studio Code, Node.js (LTS) and, optionally, Python.
    Then clones your app's GitHub repository and opens it in VS Code.
    Safe to run more than once: anything already installed is skipped.

    Run it by pasting this into PowerShell:
        irm https://raw.githubusercontent.com/kaschmitter-apps/bootstrap-installer/main/install.ps1 | iex

.NOTES
    Works in Windows PowerShell 5.1 and PowerShell 7+. Because it is usually run
    through "| iex", it must never call 'exit' (that would close the window).
#>

function Install-AppBootstrap {
    # Native tools (git, winget, code) print warnings to stderr; in PowerShell 5.1 'Stop' would turn
    # those into fatal errors. Commands that must succeed use -ErrorAction Stop instead.
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'   # Download progress bars are very slow in PowerShell 5.1
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Org = 'kaschmitter-apps'
    $TemplateUrl = "https://github.com/$Org/bootstrap"
    $MinNodeMajor = 20
    $ProjectsRoot = Join-Path $HOME 'Projects'
    $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

    # --- Helpers -------------------------------------------------------------

    function Write-Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
    function Write-Ok($text)   { Write-Host "   $text" -ForegroundColor Green }
    function Write-Note($text) { Write-Host "   $text" -ForegroundColor Yellow }
    function Write-Bad($text)  { Write-Host "   $text" -ForegroundColor Red }

    function Test-Command($cmd) {
        return [bool](Get-Command -Name $cmd -ErrorAction SilentlyContinue)
    }

    # VS Code can be installed without its 'code' command on the PATH, so also look in
    # its standard install folders and add the one we find to this window's PATH.
    function Find-VSCode {
        if (Test-Command code) { return $true }
        $folders = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin'),
            (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin')
        )
        foreach ($folder in $folders) {
            if (Test-Path (Join-Path $folder 'code.cmd')) {
                $env:Path = "$env:Path;$folder"
                return $true
            }
        }
        return $false
    }

    # The extensions a project recommends, from its .vscode/extensions.json. Only well-formed
    # IDs (publisher.name) are returned, because they are passed to code.cmd, a batch file.
    function Get-RecommendedExtensions($projectFolder) {
        $file = Join-Path $projectFolder '.vscode\extensions.json'
        if (-not (Test-Path $file)) { return @() }
        try {
            # extensions.json may contain // comments, which ConvertFrom-Json rejects.
            $json = (Get-Content $file -Raw) -replace '(?m)^\s*//.*$', ''
            $ids = @((ConvertFrom-Json $json).recommendations)
        } catch {
            Write-Note "Couldn't read the project's recommended extensions list."
            return @()
        }
        return @($ids | Where-Object { $_ -is [string] -and $_ -match '^[A-Za-z0-9][\w-]*\.[A-Za-z0-9][\w.-]*$' })
    }

    # Installs one VS Code extension. Returns $true on success.
    function Install-VSCodeExtension($id) {
        # Keep the result in the log, minus VS Code's harmless deprecation warnings.
        & code --install-extension $id --force 2>&1 |
            ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch 'DeprecationWarning|DEP0|trace-deprecation|NativeCommandError' } |
            ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        return ($LASTEXITCODE -eq 0)
    }

    # True if this Windows account can approve administrator prompts. Admin accounts are
    # in the local Administrators group (S-1-5-32-544) even before a prompt is approved.
    function Test-CanElevate {
        $groups = whoami /groups /fo csv 2>$null | Out-String
        return ($groups -match 'S-1-5-32-544')
    }

    # Programs installed during this run aren't on this window's PATH yet.
    function Update-SessionPath {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machine;$user"
    }

    function Test-Winget {
        if (Test-Command winget) { return $true }
        # On a new Windows account the App Installer (winget) may exist but not be registered yet.
        # This often fails harmlessly (e.g. in Windows Sandbox), so keep it quiet.
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        } catch { }
        return (Test-Command winget)
    }

    function Install-WithWinget($id, $name) {
        Write-Host "   Installing $name with winget (a Windows permission prompt may appear)..."
        # '2>&1 | ForEach-Object' routes all output through PowerShell so the log captures it.
        & winget install --id $id --exact --source winget --silent `
            --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
            ForEach-Object { "$_" } | Out-Host
        Write-Host "   (winget finished with code $LASTEXITCODE)" -ForegroundColor DarkGray
    }

    function Invoke-Download($url, $fileName) {
        $path = Join-Path $env:TEMP $fileName
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
        return $path
    }

    # Runs a downloaded installer and waits for it, with a time limit so a stuck installer
    # can't hang setup forever. Exit code 3010 means "succeeded, restart recommended".
    function Invoke-Installer($name, $file, $arguments, [switch]$Elevate, $timeoutMinutes = 15) {
        $options = @{ FilePath = $file; ArgumentList = $arguments; PassThru = $true; ErrorAction = 'Stop' }
        if ($Elevate) { $options.Verb = 'RunAs' }
        Write-Host "   Running: $(Split-Path $file -Leaf) $($arguments -join ' ')" -ForegroundColor DarkGray
        $process = Start-Process @options
        if (-not $process.WaitForExit($timeoutMinutes * 60 * 1000)) {
            throw "The $name installer didn't finish within $timeoutMinutes minutes. Look for a hidden installer window, then run this again."
        }
        Write-Host "   ($name installer finished with code $($process.ExitCode))" -ForegroundColor DarkGray
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw "The $name installer failed (code $($process.ExitCode))."
        }
    }

    # Direct-download installers, used when winget isn't available.
    function Install-GitDirect {
        $release = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing -ErrorAction Stop
        $pattern = if ($Arch -eq 'arm64') { '^Git-.*-arm64\.exe$' } else { '^Git-.*-64-bit\.exe$' }
        $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) { throw "Couldn't find a Git installer to download." }
        Write-Host "   Downloading $($asset.name)..."
        $file = Invoke-Download $asset.browser_download_url $asset.name
        Write-Host "   Installing Git (a Windows permission prompt may appear)..."
        Invoke-Installer 'Git' $file @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-')
    }

    function Install-VSCodeDirect {
        $url = "https://update.code.visualstudio.com/latest/win32-$Arch-user/stable"
        Write-Host "   Downloading VS Code..."
        $file = Invoke-Download $url 'VSCodeUserSetup.exe'
        Write-Host "   Installing VS Code..."
        Invoke-Installer 'VS Code' $file @('/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode')
    }

    function Install-NodeDirect {
        # Store the list first: PowerShell 5.1 pipes a JSON array as one object, not item by item.
        $releases = Invoke-RestMethod 'https://nodejs.org/dist/index.json' -UseBasicParsing -ErrorAction Stop
        $lts = $releases | Where-Object { $_.lts } | Select-Object -First 1
        $msi = "node-$($lts.version)-$Arch.msi"
        Write-Host "   Downloading Node.js $($lts.version)..."
        $file = Invoke-Download "https://nodejs.org/dist/$($lts.version)/$msi" $msi
        Write-Host "   Installing Node.js (a Windows permission prompt will appear)..."
        # The Windows Installer writes its own detailed log next to the installer log.
        # "!" writes each line to disk immediately, so the log survives a crash.
        $msiLog = Join-Path $logDir ("nodejs-msi-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
        Write-Host "   Node.js installer log: $msiLog" -ForegroundColor DarkGray
        Invoke-Installer 'Node.js' 'msiexec.exe' @('/i', "`"$file`"", '/passive', '/norestart', '/l*v!', "`"$msiLog`"") -Elevate
    }

    function Get-NodeMajor {
        if (-not (Test-Command node)) { return 0 }
        return [int]((node --version).Trim().TrimStart('v').Split('.')[0])
    }

    # 'python' can be a Microsoft Store placeholder that does nothing, so check it reports a version.
    function Test-Python {
        foreach ($candidate in @('python', 'python3')) {
            if (Test-Command $candidate) {
                $out = & $candidate --version 2>$null
                if ($LASTEXITCODE -eq 0 -and $out -match 'Python \d') { return $true }
            }
        }
        return $false
    }

    function Get-LatestPythonWingetId {
        $ids = & winget search --id Python.Python.3 --source winget --accept-source-agreements 2>$null |
            Select-String -Pattern 'Python\.Python\.3\.(\d+)' -AllMatches |
            ForEach-Object { $_.Matches } |
            ForEach-Object { [int]$_.Groups[1].Value } |
            Sort-Object -Unique -Descending
        if ($ids) { return "Python.Python.3.$($ids[0])" }
        return $null
    }

    # Asks until the answer starts with one of the allowed letters; returns that letter.
    function Read-Choice($prompt, $letters) {
        while ($true) {
            $answer = (Read-Host "   $prompt").Trim().ToLower()
            if ($answer -and ($letters -contains $answer.Substring(0, 1))) {
                Write-Host "   (answered: $($answer.Substring(0, 1)))" -ForegroundColor DarkGray   # Typed answers aren't in the log otherwise
                return $answer.Substring(0, 1)
            }
            Write-Note "Please type $($letters -join ' or ')."
        }
    }

    # One "Before you start" item. Returns $false if the user chooses to quit for now.
    function Confirm-Prerequisite($question, $title, $steps, $url) {
        Write-Host ""
        if ((Read-Choice "$question (y/n)" @('y', 'n')) -eq 'y') { return $true }

        $opened = $false
        while ($true) {
            Write-Host ""
            Write-Host "   How to: $title" -ForegroundColor Cyan
            $number = 1
            foreach ($step in $steps) {
                Write-Host "     $number. $step"
                $number++
            }
            if ($url -and -not $opened) {
                Write-Host "   Opening $url in your browser..." -ForegroundColor DarkGray
                try { Start-Process $url } catch { }
                $opened = $true
            }
            Write-Host ""
            $answer = Read-Choice "Is it done? (y = yes, continue / n = not yet, show the steps again / q = quit for now)" @('y', 'n', 'q')
            if ($answer -eq 'y') { return $true }
            if ($answer -eq 'q') { return $false }
        }
    }

    # --- Start ---------------------------------------------------------------

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  App Bootstrap Starter - computer setup" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "This installs the tools you need, then opens your app in VS Code."
    Write-Host "It's safe to run again; anything already installed is skipped."

    if ($env:OS -ne 'Windows_NT') {
        Write-Bad "This installer is for Windows. On a Mac, follow the README instead."
        return
    }

    # --- Before you start: accounts the installer can't create for you -------

    Write-Step "Before you start"
    Write-Host "   A few quick questions to make sure you have everything you need."

    $checklist = @(
        @{
            Question = "Do you have a GitHub account?"
            Title    = "Create a GitHub account"
            Url      = 'https://github.com/signup'
            Steps    = @(
                "On the GitHub sign-up page, enter your email address, a password, and a username.",
                "GitHub emails you a code. Enter it to verify your email.",
                "Choose the Free plan if asked.",
                "Recommended: turn on two-factor authentication (your picture, top right -> Settings -> Password and authentication).",
                "Send your GitHub username to the owner of $Org so they can invite you."
            )
        },
        @{
            Question = "Are you a member of the $Org organization on GitHub?"
            Title    = "Join the $Org organization"
            Url      = "https://github.com/orgs/$Org/invitation"
            Steps    = @(
                "Send your GitHub username to the owner of $Org and ask them to invite you.",
                "Look for an email from GitHub saying you've been invited to join $Org.",
                "Click the link in the email (or use the page that just opened) and click 'Join $Org'.",
                "To check: open https://github.com/$Org. You should see the 'bootstrap' repository."
            )
        },
        @{
            Question = "Have you created your app's repository from the starter template?"
            Title    = "Create your app's repository"
            Url      = $TemplateUrl
            Steps    = @(
                "On the starter template page, click the green 'Use this template' button -> 'Create a new repository'.",
                "Owner: choose '$Org' (not your personal account).",
                "Repository name: short, lowercase, with dashes. For example: truck-tracker",
                "Choose 'Private'.",
                "Click 'Create repository'.",
                "Keep the page open. The installer will ask for its address (copy it from the browser's address bar)."
            )
        },
        @{
            Question = "Do you have a Claude plan that includes Claude Code?"
            Title    = "Get a Claude plan"
            Url      = 'https://claude.com/pricing'
            Steps    = @(
                "If your company provides Claude (a Team or Enterprise plan), ask your manager or IT for a seat that includes Claude Code.",
                "Otherwise, on the pricing page choose a plan that includes Claude Code (for example Pro or Max).",
                "Sign up with your work email and complete the purchase.",
                "You'll sign in to Claude inside VS Code at the end of setup."
            )
        }
    )

    foreach ($item in $checklist) {
        if (-not (Confirm-Prerequisite $item.Question $item.Title $item.Steps $item.Url)) {
            Write-Host ""
            Write-Note "No problem. Nothing has been installed yet."
            Write-Note "When you're ready, run the same command again to pick up where you left off."
            return
        }
    }
    Write-Ok "All set. Starting the installation."

    # --- Check what's needed before changing anything --------------------------

    $needGit = -not (Test-Command git)
    $needCode = -not (Find-VSCode)
    $needNode = (Get-NodeMajor) -lt $MinNodeMajor

    # Git and Node.js install for the whole computer, which needs administrator approval.
    if (($needGit -or $needNode) -and -not (Test-CanElevate)) {
        $missing = @()
        if ($needGit) { $missing += 'Git' }
        if ($needNode) { $missing += "Node.js (version $MinNodeMajor or newer)" }
        Write-Host ""
        Write-Bad "This computer needs $($missing -join ' and '), which require administrator"
        Write-Bad "permission to install, and your Windows account doesn't appear to have it."
        Write-Note "Ask your IT team to install: $($missing -join ', ')."
        Write-Note "Then run this installer again; it will skip what's already installed."
        $answer = Read-Host "   Try anyway? (y/N)"
        if ($answer -notmatch '^(y|yes)$') { return }
    }

    $useWinget = Test-Winget
    if (-not $useWinget) {
        Write-Note "winget isn't available on this computer; downloading installers directly instead."
    }

    # --- Git -----------------------------------------------------------------

    Write-Step "Git"
    if (-not $needGit) {
        Write-Ok "Already installed: $((git --version) -replace '^git version ', '')"
    } else {
        if ($useWinget) { Install-WithWinget 'Git.Git' 'Git' } else { Install-GitDirect }
        Update-SessionPath
        if (Test-Command git) { Write-Ok "Installed." } else { Write-Bad "Git didn't install. Install it from https://git-scm.com/downloads and run this again."; return }
    }

    # --- VS Code -------------------------------------------------------------

    Write-Step "Visual Studio Code"
    if (-not $needCode) {
        Write-Ok "Already installed."
    } else {
        if ($useWinget) { Install-WithWinget 'Microsoft.VisualStudioCode' 'VS Code' } else { Install-VSCodeDirect }
        Update-SessionPath
        if (Find-VSCode) { Write-Ok "Installed." } else { Write-Bad "VS Code didn't install. Install it from https://code.visualstudio.com and run this again."; return }
    }

    # --- Node.js -------------------------------------------------------------

    Write-Step "Node.js"
    $nodeMajor = Get-NodeMajor
    if ($nodeMajor -ge $MinNodeMajor) {
        Write-Ok "Already installed: $((node --version).Trim())"
    } else {
        if ($nodeMajor -gt 0) { Write-Note "Version $nodeMajor is too old; installing the current LTS version." }
        if ($useWinget) { Install-WithWinget 'OpenJS.NodeJS.LTS' 'Node.js LTS' } else { Install-NodeDirect }
        Update-SessionPath
        if ((Get-NodeMajor) -ge $MinNodeMajor) { Write-Ok "Installed: $((node --version).Trim())" } else { Write-Bad "Node.js didn't install. Install the LTS version from https://nodejs.org and run this again."; return }
    }

    # --- Python (optional) ---------------------------------------------------

    Write-Step "Python (optional)"
    if (Test-Python) {
        Write-Ok "Already installed."
    } else {
        $answer = Read-Host "   Python is only needed for Python projects. Install it? (y/N)"
        if ($answer -match '^(y|yes)$') {
            $pythonId = $null
            if ($useWinget) { $pythonId = Get-LatestPythonWingetId }
            if ($pythonId) {
                Install-WithWinget $pythonId 'Python'
                Update-SessionPath
                if (Test-Python) { Write-Ok "Installed." } else { Write-Note "Python may need a new PowerShell window to be found." }
            } else {
                Write-Note "Couldn't install Python automatically. Get it from https://www.python.org/downloads if you need it."
            }
        } else {
            Write-Ok "Skipped."
        }
    }

    # --- Git identity (needed to save your work) -----------------------------

    Write-Step "Your name for saved changes"
    $gitName = (git config --global user.name) 2>$null
    $gitEmail = (git config --global user.email) 2>$null
    if ($gitName -and $gitEmail) {
        Write-Ok "Already set: $gitName <$gitEmail>"
    } else {
        Write-Host "   Git labels each saved change with your name and email."
        while (-not $gitName) { $gitName = (Read-Host "   Your full name").Trim() }
        while (-not $gitEmail) { $gitEmail = (Read-Host "   Your email (ideally the one you use for GitHub)").Trim() }
        git config --global user.name $gitName
        git config --global user.email $gitEmail
        Write-Ok "Saved."
    }

    # --- Clone the app and open it -------------------------------------------

    Write-Step "Your app"
    Write-Host "   Paste your app's GitHub address, for example:"
    Write-Host "   https://github.com/$Org/truck-tracker"
    Write-Host "   (Haven't created it yet? See step 1 of the playbook, or press Enter to skip.)"

    $repoUrl = $null
    $repoName = $null
    while ($true) {
        $answer = (Read-Host "   GitHub address").Trim()
        if (-not $answer) { break }
        if ($answer -match '^(?:https://)?github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:[/?#].*)?$') {
            $repoUrl = "https://github.com/$($Matches[1])/$($Matches[2]).git"
            $repoName = $Matches[2]
            break
        }
        Write-Note "That doesn't look like a GitHub repository address. Try again, or press Enter to skip."
    }

    if (-not $repoUrl) {
        Write-Note "Skipped. Run this installer again when your repository is ready."
    } else {
        $target = Join-Path $ProjectsRoot $repoName
        if (Test-Path (Join-Path $target '.git')) {
            Write-Ok "Already downloaded to $target"
        } elseif (Test-Path $target) {
            Write-Bad "$target already exists but isn't a Git repository. Move or rename it, then run this again."
            return
        } else {
            New-Item -ItemType Directory -Force $ProjectsRoot | Out-Null
            Write-Host "   Downloading to $target"
            Write-Host "   If a GitHub sign-in window opens, sign in. You only need to do this once;"
            Write-Host "   Git remembers it for this computer."
            git clone $repoUrl $target 2>&1 | ForEach-Object { "$_" } | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Bad "Couldn't download the repository. Check the address, and that your GitHub account has access to it."
                return
            }
            Write-Ok "Downloaded."
        }

        Write-Step "VS Code extensions"
        [void](Find-VSCode)   # Re-add VS Code to PATH in case a later install refreshed it
        # Claude Code first (always), then everything the project recommends.
        $extensions = @('anthropic.claude-code') + @(Get-RecommendedExtensions $target |
            Where-Object { $_ -ne 'anthropic.claude-code' })
        Write-Host "   Installing $($extensions.Count) extensions. This can take a few minutes."
        $failed = @()
        foreach ($id in $extensions) {
            Write-Host "   - $id"
            if (-not (Install-VSCodeExtension $id)) { $failed += $id }
        }
        if ($failed.Count -eq 0) {
            Write-Ok "All extensions installed."
        } elseif ($failed -contains 'anthropic.claude-code') {
            Write-Bad "Couldn't install the Claude Code extension. In VS Code, open the Extensions panel and install 'Claude Code'."
        }
        if ($failed | Where-Object { $_ -ne 'anthropic.claude-code' }) {
            Write-Note "Couldn't install: $(($failed | Where-Object { $_ -ne 'anthropic.claude-code' }) -join ', ')."
            Write-Note "In VS Code: Ctrl+Shift+P -> 'Install Workspace Recommended Extensions'."
        }

        Write-Step "Opening VS Code"
        & code $target 2>&1 | Out-Null
        Write-Ok "VS Code is opening your app."
    }

    # --- Done ----------------------------------------------------------------

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "  Setup complete" -ForegroundColor Green
    Write-Host "=============================================" -ForegroundColor Green
    Write-Host "Next, in VS Code:"
    Write-Host "  1. Click 'Yes, I trust the authors' if asked."
    Write-Host "  2. If VS Code asks you to sign in to GitHub or GitHub Copilot, you can skip it."
    Write-Host "     Your GitHub sign-in for code is already saved."
    Write-Host "  3. Ctrl+Shift+P -> 'Tasks: Run Task' -> 'setup-and-refresh', then 'start-app'."
    Write-Host "  4. Open the Claude Code panel. When asked how to sign in, choose 'Claude account'"
    Write-Host "     (your Claude subscription), not 'Anthropic Console'. Then say: 'Help me finish setup.'"
    Write-Host ""
}

# --- Log everything shown on screen to a file, for troubleshooting ---------------
# Normally the log goes to the user's temp folder. Test runs (test\sandbox.wsb) set
# BOOTSTRAP_LOG_DIR to a folder shared with the host PC, so logs survive the sandbox.

$logDir = if ($env:BOOTSTRAP_LOG_DIR) { $env:BOOTSTRAP_LOG_DIR } else { $env:TEMP }
$logFile = Join-Path $logDir ("bootstrap-installer-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$logging = $false
try {
    Start-Transcript -Path $logFile -ErrorAction Stop | Out-Null
    $logging = $true
} catch { }

try {
    Write-Host "Installer log: $logFile" -ForegroundColor DarkGray
    Write-Host "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), $env:PROCESSOR_ARCHITECTURE" -ForegroundColor DarkGray
    Install-AppBootstrap
} catch {
    Write-Host ""
    Write-Host "Setup stopped because of an error:" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Details for troubleshooting:" -ForegroundColor DarkGray
    Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host "It's safe to run the installer again. If it keeps failing, send the log file below to whoever set up your account." -ForegroundColor Yellow
} finally {
    if ($logging) {
        Stop-Transcript | Out-Null
        Write-Host "Log saved to: $logFile" -ForegroundColor DarkGray
    }
    # In test runs, also keep winget's own detailed logs.
    if ($env:BOOTSTRAP_LOG_DIR) {
        $wingetLogs = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
        if (Test-Path $wingetLogs) {
            $dest = Join-Path $env:BOOTSTRAP_LOG_DIR ("winget-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
            Copy-Item $wingetLogs $dest -Recurse -ErrorAction SilentlyContinue
        }
    }
}
