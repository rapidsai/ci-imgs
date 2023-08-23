include "ci/shared";

# CI specific computations
def compute_ci($x):
  def compute_ci_arch($x):
    ["amd64"] |
    if
      $x.CUDA_VER > "11.2.2" and
      $x.LINUX_VER != "centos7"
    then
      . + ["arm64"]
    else
      .
    end |
    $x + {ARCHES: .};

  def compute_image_name($x):
    compute_repo($x) as $repo |
    compute_tag_prefix($x) as $tag_prefix |
    "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
    $x + {IMAGE_NAME: .};

  ($x.exclude // []) as $excludes |
  $x | del(.exclude) |
  keys_unsorted as $matrix_keys |
  to_entries |
  map(.value) |
  [
    combinations |
    lists2dict($matrix_keys; .) |
    filter_excludes(.; $excludes) |
    compute_ci_arch(.) |
    compute_image_name(.)
  ] |
  {include: .};

# Wheels specific computations
def compute_wheels($x):
  def compute_wheels_arch($x):
    ["amd64"] |
    if
      ["ubuntu18.04", "centos7"] | index($x.LINUX_VER) != null
    then
      .
    else
      . + ["arm64"]
    end |
    $x + {ARCHES: .};

  def compute_manylinux_version($x):
    if
      ["ubuntu18.04", "ubuntu20.04"] | index($x.LINUX_VER) != null
    then
      "manylinux_2_31"
    else
      "manylinux_2_17"
    end |
    $x + {MANYLINUX_VER: .};

  def compute_image_name($x):
    compute_repo($x) as $repo |
    compute_tag_prefix($x) as $tag_prefix |
    "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
    $x + {IMAGE_NAME: .};

  ($x.exclude // []) as $excludes |
  $x | del(.exclude) |
  keys_unsorted as $matrix_keys |
  to_entries |
  map(.value) |
  [
    combinations |
    lists2dict($matrix_keys; .) |
    filter_excludes(.; $excludes) |
    compute_wheels_arch(.) |
    compute_manylinux_version(.) |
    compute_image_name(.)
  ] |
  {include: .};

# Main function to compute matrix
def compute_matrix($type; $input):
  if $type == "ci" then
    compute_ci($input)
  elif $type == "wheels" then
    compute_wheels($input)
  else
    error("Unknown matrix type: " + $type)
  end;
