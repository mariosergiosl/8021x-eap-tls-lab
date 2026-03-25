#!/bin/bash
#===============================================================================
#
# FILE: update_git.bash
#
# USAGE: update_git.bash [commit message]
#
# DESCRIPTION: This script updates a Git repository with the latest changes.
#              If a commit message is provided as an argument, it uses that.
#              Otherwise, it automatically uses a default message with the
#              list of changed files.
#
# STEPS:       1. Updates Git (Add, Commit, Pull, Push, Tags)
#
# OPTIONS:
#    -h, --help      Display this help message
#    -v, --version   Display script version
#
# REQUIREMENTS: git
#
# BUGS:
#
# NOTES: Adapted for MobaXterm and general Git repository usage.
#
# AUTHOR:
#    Mario Luz (ml), mario.mssl[at]gmail.com
#
# COMPANY:
#
# VERSION: 3.0
# CREATED: 2024-11-18 17:00:00
# REVISION: 2025-06-27 11:22:00 
# REVISION: 2025-12-05 14:48:00
# REVISION: 2026-03-25 14:20:00 # Adapted for 8021x-eap-tls-lab repository
#===============================================================================

# Stop execution on any error
set -e

# Set script version
SCRIPT_VERSION="3.0"

# --- CONFIG ---
# Using current directory to support MobaXterm mapped drives on Windows
PROJECT_ROOT="$(pwd)"

# ------------------------------------------------------------------------------
# NAME: show_help
# DESCRIPTION: Displays the usage instructions and available options.
# PARAMETER: None
# ------------------------------------------------------------------------------
show_help() {
  cat << EOF
Usage: $0 [OPTIONS] [commit message]

This script updates a Git repository with the latest changes.
Full Release Pipeline: Git Add -> Git Commit -> Git Pull -> Git Push

OPTIONS:
  -h, --help      Display this help message
  -v, --version   Display script version

Examples:
  $0 "My commit message"
  $0 -m "New feature: Network Scan"
  $0
EOF
}

# ------------------------------------------------------------------------------
# NAME: show_version
# DESCRIPTION: Displays the current version of the script.
# PARAMETER: None
# ------------------------------------------------------------------------------
show_version() {
  echo "$0 version $SCRIPT_VERSION"
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
commit_message=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    -v|--version)
      show_version
      exit 0
      ;;
    -m)
      commit_message="$2"
      shift 2
      ;;
    *)
      if [[ -z "$commit_message" ]]; then
        commit_message="$1"
      fi
      shift
      ;;
  esac
done

# ------------------------------------------------------------------------------
# STEP 1: GIT AUTOMATION
# ------------------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo ">>> STEP 1: GIT SYNC (Push & Tags)"
echo "----------------------------------------------------------------"

# Check if there are any staged changes to commit
if [[ -z $(git status --porcelain) ]]; then
    # Even if no changes to commit, still pull and push for tags in case
    # there are remote updates or only tags need pushing.
    echo "No local changes to add."
    echo "Pulling latest changes from remote repository..."
    git pull origin main
    git push origin main
    git push origin --tags
else
    # Auto-commit message if not exist
    if [[ -z "$commit_message" ]]; then
        # Get the list of updated files 
        updated_files=$(git diff --cached --name-only | tr '\n' ' ')
        commit_message="Update: $updated_files"
        # Use the default commit message if none is provided via argument
        if [[ -z "$commit_message" || "$commit_message" == "Update: " ]]; then 
            commit_message="Minor updates"
        fi
    fi

    echo "Adding all changes (including new files) to staging area..."
    git add .
    echo "Committing with message: '$commit_message'"
    git commit -m "$commit_message"

    # Pull the latest changes from the remote repository BEFORE pushing 
    # This helps avoid conflicts if others have pushed
    echo "Pulling latest changes from remote repository..."
    git pull origin main

    # Check for merge conflicts after pulling
    if [[ $(git status --porcelain | grep "^UU" | wc -l) -gt 0 ]]; then
        echo "!!! Merge conflicts detected after pulling. Please resolve !!!"
        echo "Aborting push. Run 'git status' to see conflicted files."
        exit 1
    fi

    # Push the changes to the remote repository
    echo "Pushing changes to remote repository..."
    git push origin main

    # Push the tags to the remote repository
    echo "Pushing tags to remote repository..."    
    git push origin --tags
fi

# ------------------------------------------------------------------------------
# GRAND FINALE
# ------------------------------------------------------------------------------
echo "================================================================"
echo "   GRAND FINALE: SUCCESS! "
echo "   Code Pushed to Git Repository."
echo "================================================================"