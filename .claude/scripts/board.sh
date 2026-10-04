#!/usr/bin/env bash
# board.sh — the ticket state baton, on the GitHub Project's Status field.
#
# State lives in the Status field of the "Starquake Recompiled" user Project,
# so the maintainer can drag a card (web or mobile) and Claude can set the same
# value from the CLI — one source of truth either way. `ready to merge` is a PR
# LABEL and is not managed here.
#
# The opaque node ids below are why this file exists: they belong in one place
# rather than copy-pasted into every skill. Ported from starquake/numbergame.
#
#   ./board.sh state <issue> "<Status>"   set an issue's state
#   ./board.sh get   <issue>              print an issue's state
#   ./board.sh list  "<Status>"           list issue numbers in that state
#   ./board.sh states                     print the valid state names
#
# Requires the `project` scope on the gh token.
set -euo pipefail

# The board is a USER project, while the repo belongs to the org: two owners.
PROJECT_NUMBER=5
PROJECT_OWNER=starquake
REPO=zx-recompiled/starquake-recompiled
PROJECT_ID="PVT_kwHOAA_wQM4BjSuM"
STATUS_FIELD_ID="PVTSSF_lAHOAA_wQM4BjSuMzhiHmXE"

# Where `state` records its own writes for the board monitor to ignore
# (work-the-board). Transient by design — losing it costs one spurious
# notification, never a missed maintainer move.
SELF_SET_FILE="${BOARD_SELF_SET_FILE:-${TMPDIR:-/tmp}/starquake-board-selfset}"

# Status name -> single-select option id, looked up LIVE by name.
#
# Reordering a single-select's options REPLACES every option, minting new ids
# and clearing every item's value. Names are the stable handle; ids are not,
# so they are never hardcoded here.
option_id() {
  local id
  id=$(gh api graphql -f query="{ user(login:\"$PROJECT_OWNER\"){ projectV2(number: $PROJECT_NUMBER){
        field(name:\"Status\"){ ... on ProjectV2SingleSelectField { options{ id name } } } } } }" \
      --jq ".data.user.projectV2.field.options[] | select(.name==\"$1\") | .id" 2>/dev/null)
  if [ -z "$id" ]; then
    echo "unknown state: $1" >&2
    echo "valid: $(gh api graphql -f query="{ user(login:\"$PROJECT_OWNER\"){ projectV2(number: $PROJECT_NUMBER){
          field(name:\"Status\"){ ... on ProjectV2SingleSelectField { options{ name } } } } } }" \
        --jq '[.data.user.projectV2.field.options[].name] | join(", ")')" >&2
    return 1
  fi
  printf '%s' "$id"
}

# Every item on the board as "number|item id|status", one per line, paged.
#
# Read from the PROJECT side: an issue in an org repo does not list a user
# project under `issue.projectItems` (it comes back empty since the repo moved
# to zx-recompiled, #137), so the issue cannot be asked for its own item.
# Matching the repository too keeps another repo's issue of the same number out.
items() {
  gh api graphql --paginate -f query="query(\$endCursor: String){ user(login:\"$PROJECT_OWNER\"){
        projectV2(number: $PROJECT_NUMBER){ items(first:100, after: \$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ id content{ ... on Issue { number repository{ nameWithOwner } } }
            fieldValueByName(name:\"Status\"){ ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }" \
    --jq ".data.user.projectV2.items.nodes[]
          | select(.content.repository.nameWithOwner==\"$REPO\")
          | \"\\(.content.number)|\\(.id)|\\(.fieldValueByName.name // \"(unset)\")\""
}

# Item id for an issue number, adding the issue to the project if it is missing
# (a hand-filed issue may never have been added).
item_id() {
  local issue="$1" id
  id=$(items | awk -F'|' -v n="$issue" '$1==n { print $2; exit }')
  if [ -z "$id" ]; then
    id=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
          --url "https://github.com/$REPO/issues/$issue" \
          --format json --jq .id)
  fi
  printf '%s' "$id"
}

case "${1:-}" in
  state)
    issue="$2"; want="$3"
    opt=$(option_id "$want")
    item=$(item_id "$issue")
    gh api graphql -f query="mutation{updateProjectV2ItemFieldValue(input:{
        projectId:\"$PROJECT_ID\", itemId:\"$item\", fieldId:\"$STATUS_FIELD_ID\",
        value:{singleSelectOptionId:\"$opt\"}}){projectV2Item{id}}}" >/dev/null
    # Record that this move was OURS, so the board monitor does not wake the
    # agent to report a change the agent just made. The monitor consumes (and
    # removes) the matching entry when it sees the transition.
    printf '%s|%s\n' "$issue" "$want" >> "$SELF_SET_FILE"
    echo "#$issue -> $want"
    ;;
  get)
    items | awk -F'|' -v n="$2" '$1==n { print $3; exit }'
    ;;
  list)
    items | awk -F'|' -v s="$2" '$3==s { print $1 }' | sort -n
    ;;
  states)
    gh api graphql -f query="{ user(login:\"$PROJECT_OWNER\"){ projectV2(number: $PROJECT_NUMBER){
        field(name:\"Status\"){ ... on ProjectV2SingleSelectField { options{ name } } } } } }" \
      --jq '.data.user.projectV2.field.options[].name'
    ;;
  *)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
