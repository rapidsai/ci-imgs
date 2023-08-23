def compute_repo($x):
    if
      env.BUILD_TYPE == "pull-request"
    then
      "staging"
    else
      $x.IMAGE_REPO
    end;

# Compute tag prefix
def compute_tag_prefix($x):
if
    env.BUILD_TYPE == "branch"
then
    ""
else
    $x.IMAGE_REPO + "-" + env.PR_NUM + "-"
end;

# Checks the current entry to see if it matches the given exclude
def matches($entry; $exclude):
all($exclude | to_entries | .[]; $entry[.key] == .value);

# Checks the current entry to see if it matches any of the excludes.
def filter_excludes($entry; $excludes):
select(any($excludes[]; matches($entry; .)) | not);

# Convert lists to dictionary
def lists2dict($keys; $values):
reduce range($keys | length) as $ind ({}; . + {($keys[$ind]): $values[$ind]});
