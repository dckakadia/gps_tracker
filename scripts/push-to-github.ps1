param(
  [string]$RepoName = 'gps_tracker',
  [string]$Visibility = 'public',
  [string]$Branch = 'main'
)

Write-Output "Preparing to push repository as '$RepoName' (visibility: $Visibility) on branch $Branch"

if (-not (Test-Path -Path .git -PathType Container)) {
  Write-Output 'Initializing git repository...'
  git init
}

git add .
try { git commit -m 'Initial commit' } catch { Write-Output 'No changes to commit or commit failed' }

if (Get-Command gh -ErrorAction SilentlyContinue) {
  Write-Output "Creating GitHub repo and pushing using gh..."
  gh repo create $RepoName --$Visibility --source=. --remote=origin --push --public
} else {
  Write-Output "GitHub CLI 'gh' not found. Please install it or create a repo manually."
  Write-Output "Manual steps:"
  Write-Output "  1) Create a repo on github.com"
  Write-Output "  2) git remote add origin <git_url>"
  Write-Output "  3) git push -u origin $Branch"
}

Write-Output 'Done.'
