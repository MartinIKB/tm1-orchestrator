<#
================================================================================
  TM1 Orchestrator Framework - Module: TM1O.Git.psm1 - Version 0.1 (2026-03-13)
================================================================================

 Git-Konfiguration und spaetere Git-Integration fuer das TM1 Orchestrator
 Framework.

 Dieses Modul kapselt zunaechst:

   - Laden der Git-Repository-Konfiguration
   - Aufloesen instanzbezogener Repository-Einstellungen
   - Validierung der aufgeloesten Repository-Konfiguration

 Die eigentlichen Git-Operationen wie clone, pull, worktree usw. koennen
 spaeter in diesem Modul ergaenzt werden.

#>

function _TM1O_GitLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($null -ne $Context) {
        Write-TM1OLog -Context $Context -Message $Message -Level $Level
    }
}

function Get-TM1OGitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [object]$Context
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $frameworkRoot = Split-Path -Path $PSScriptRoot -Parent
        $ConfigPath = Join-Path -Path $frameworkRoot -ChildPath "config\git-repositories.json"
    }

    _TM1O_GitLog -Context $Context -Message ("Lade Git-Repository-Konfiguration aus '{0}'." -f $ConfigPath) -Level "Debug"

    if (-not (Test-Path $ConfigPath)) {
        throw "config/git-repositories.json wurde nicht gefunden: $ConfigPath"
    }

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Fehler beim Lesen oder Parsen von '$ConfigPath': $($_.Exception.Message)"
    }

    if (-not $cfg.defaults) {
        throw "In '$ConfigPath' wurde kein 'defaults'-Objekt gefunden."
    }

    if (-not $cfg.repositories) {
        throw "In '$ConfigPath' wurde kein 'repositories'-Array gefunden."
    }

    return $cfg
}

function Get-TM1ORepositoryConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instance,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [object]$Context
    )

    $instNorm = $Instance.Trim().ToUpper()

    _TM1O_GitLog -Context $Context -Message ("Loese Git-Repository-Konfiguration fuer Instanz '{0}' auf." -f $instNorm) -Level "Debug"

    $gitCfg = Get-TM1OGitConfig -ConfigPath $ConfigPath -Context $Context
    $defaults = $gitCfg.defaults

    $repoCfg = $gitCfg.repositories | Where-Object { $_.instance.ToString().Trim().ToUpper() -eq $instNorm }

    if (-not $repoCfg) {
        throw "In config/git-repositories.json wurde keine Instanz '$instNorm' gefunden."
    }

    $repositoryName = if ($repoCfg.repositoryName) { [string]$repoCfg.repositoryName } else { "" }
    $remoteName = if ($repoCfg.remoteName) { [string]$repoCfg.remoteName } else { [string]$defaults.remoteName }
    $mainBranch = if ($repoCfg.mainBranch) { [string]$repoCfg.mainBranch } else { [string]$defaults.mainBranch }
    $rawBranch = if ($repoCfg.rawBranch) { [string]$repoCfg.rawBranch } else { [string]$defaults.rawBranch }
    $sshConfigPath = if ($repoCfg.sshConfigPath) { [string]$repoCfg.sshConfigPath } else { [string]$defaults.sshConfigPath }
    $tm1RepoRoot = [string]$defaults.tm1RepoRoot
    $tm1BuildRoot = [string]$defaults.tm1BuildRoot
    $repositoryUrlPattern = [string]$defaults.repositoryUrlPattern

    if ([string]::IsNullOrWhiteSpace($repositoryName)) {
        throw "Fuer Instanz '$instNorm' fehlt 'repositoryName'."
    }

    if ([string]::IsNullOrWhiteSpace($remoteName)) {
        throw "In der Git-Konfiguration fehlt 'remoteName'."
    }

    if ([string]::IsNullOrWhiteSpace($mainBranch)) {
        throw "In der Git-Konfiguration fehlt 'mainBranch'."
    }

    if ([string]::IsNullOrWhiteSpace($rawBranch)) {
        throw "In der Git-Konfiguration fehlt 'rawBranch'."
    }

    if ([string]::IsNullOrWhiteSpace($sshConfigPath)) {
        throw "In der Git-Konfiguration fehlt 'sshConfigPath'."
    }

    if ([string]::IsNullOrWhiteSpace($tm1RepoRoot)) {
        throw "In der Git-Konfiguration fehlt 'tm1RepoRoot'."
    }

    if ([string]::IsNullOrWhiteSpace($tm1BuildRoot)) {
        throw "In der Git-Konfiguration fehlt 'tm1BuildRoot'."
    }

    if ([string]::IsNullOrWhiteSpace($repositoryUrlPattern)) {
        throw "In der Git-Konfiguration fehlt 'repositoryUrlPattern'."
    }

    $localRepoPath = if ($repoCfg.localRepoPath) {
        [string]$repoCfg.localRepoPath
    }
    else {
        Join-Path -Path $tm1RepoRoot -ChildPath $instNorm
    }

    $localBuildPath = if ($repoCfg.localBuildPath) {
        [string]$repoCfg.localBuildPath
    }
    else {
        Join-Path -Path $tm1BuildRoot -ChildPath $instNorm
    }

    $repositoryUrl = if ($repoCfg.repositoryUrl) {
        [string]$repoCfg.repositoryUrl
    }
    else {
        $repositoryUrlPattern.Replace("{repositoryName}", $repositoryName)
    }

    $result = [PSCustomObject]@{
        Instance       = $instNorm
        RepositoryName = $repositoryName
        RepositoryUrl  = $repositoryUrl
        LocalRepoPath  = $localRepoPath
        LocalBuildPath = $localBuildPath
        RemoteName     = $remoteName
        MainBranch     = $mainBranch
        RawBranch      = $rawBranch
        SshConfigPath  = $sshConfigPath
    }

    _TM1O_GitLog -Context $Context -Message (
        "Git-Repository-Konfiguration fuer Instanz '{0}' aufgeloest: Repo='{1}', RepoPath='{2}', BuildPath='{3}'." -f
        $result.Instance,
        $result.RepositoryName,
        $result.LocalRepoPath,
        $result.LocalBuildPath
    ) -Level "Detail"

    return $result
}

function Test-TM1ORepositoryConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instance,

        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [object]$Context
    )

    $repoCfg = Get-TM1ORepositoryConfig -Instance $Instance -ConfigPath $ConfigPath -Context $Context

    $result = [PSCustomObject]@{
        Instance            = $repoCfg.Instance
        RepositoryName      = $repoCfg.RepositoryName
        RepositoryUrl       = $repoCfg.RepositoryUrl
        LocalRepoPath       = $repoCfg.LocalRepoPath
        LocalBuildPath      = $repoCfg.LocalBuildPath
        RepoPathExists      = (Test-Path -Path $repoCfg.LocalRepoPath)
        BuildPathExists     = (Test-Path -Path $repoCfg.LocalBuildPath)
        SshConfigPathExists = (Test-Path -Path $repoCfg.SshConfigPath)
    }

    _TM1O_GitLog -Context $Context -Message (
        "Validierung Git-Repository-Konfiguration fuer Instanz '{0}': RepoPathExists={1}; BuildPathExists={2}; SshConfigPathExists={3}." -f
        $result.Instance,
        $result.RepoPathExists,
        $result.BuildPathExists,
        $result.SshConfigPathExists
    ) -Level "Info"

    return $result
}

Export-ModuleMember -Function `
    Get-TM1OGitConfig, `
    Get-TM1ORepositoryConfig, `
    Test-TM1ORepositoryConfig