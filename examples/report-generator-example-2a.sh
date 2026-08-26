#!/bin/bash

# Fill these in
ORG="your-org-name"
PAT="your-personal-access-token"

# CSV Header
echo "name,size_MB,oldest_commit" > repos.csv

# Get all projects
projects=$(curl -s -u :$PAT "https://dev.azure.com/$ORG/_apis/projects?api-version=7.1-preview.1" | jq -r '.value[].name')

for project in $projects; do
    # Get all repos in project
    repos=$(curl -s -u :$PAT "https://dev.azure.com/$ORG/$project/_apis/git/repositories?api-version=7.1-preview.1" | jq -c '.value[]')

    echo "$repos" | while read -r repo; do
        # Get repo name and ID
        name=$(echo "$repo" | jq -r '.name')
        id=$(echo "$repo" | jq -r '.id')
        
        # Get repo size (in bytes), note: size may not be available for all Azure DevOps repos via API
        size_bytes=$(curl -s -u :$PAT "https://dev.azure.com/$ORG/$project/_apis/git/repositories/$id?api-version=7.1-preview.1" | jq -r '.size' )
        size_mb=$(awk "BEGIN{printf \"%.2f\", $size_bytes/1024/1024}")

        # Get the oldest commit
        oldest_commit=$(curl -s -u :$PAT "https://dev.azure.com/$ORG/$project/_apis/git/repositories/$id/commits?searchCriteria.$top=1&searchCriteria.itemVersion.versionType=branch&searchCriteria.itemVersion.version=master&api-version=7.1-preview.1&searchCriteria.$orderby=AuthorDate asc" | jq -r '.value[0].commitId')

        echo "$name,$size_mb,$oldest_commit" >> repos.csv

    done
done