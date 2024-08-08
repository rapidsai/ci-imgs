def compute_arch($x):
  $x + {ARCHES: ["amd64", "arm64"]};

def compute_repo($x):
  if
    env.BUILD_TYPE == "pull-request"
  then
    "staging"
  else
    $x.IMAGE_REPO
  end;

def compute_tag_prefix($x):
  if
    env.BUILD_TYPE == "branch"
  then
    ""
  else
    $x.IMAGE_REPO + "-" + env.PR_NUM + "-"
  end;

def compute_image_name($x):
  compute_repo($x) as $repo |
  compute_tag_prefix($x) as $tag_prefix |
  "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {IMAGE_NAME: .};

# Checks the current entry to see if it matches the given exclude
def matches($entry; $exclude):
  all($exclude | to_entries | .[]; $entry[.key] == .value);

# Checks the current entry to see if it matches any of the excludes.
# If so, produce no output. Otherwise, output the entry.
def filter_excludes($entry; $excludes):
  select(any($excludes[]; matches($entry; .)) | not);

def lists2dict($keys; $values):
  reduce range($keys | length) as $ind ({}; . + {($keys[$ind]): $values[$ind]});

def compute_matrix($input):
  ($input.exclude // []) as $excludes |
  $input | del(.exclude) |
  keys_unsorted as $matrix_keys |
  to_entries |
  map(.value) |
  [
    combinations |
    lists2dict($matrix_keys; .) |
    .IMAGE_REPO = .CI_IMAGE_CONFIG.IMAGE_REPO |
    .DOCKERFILE = .CI_IMAGE_CONFIG.dockerfile |
    .DOCKER_TARGET = .CI_IMAGE_CONFIG.docker_target |
    filter_excludes(.; $excludes) |
    del(.CI_IMAGE_CONFIG) |
    compute_arch(.) |
    compute_image_name(.)
  ] |
  {include: .};
