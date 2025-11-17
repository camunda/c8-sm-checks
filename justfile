# this file is a recipe file for the project

# Install all the tooling
install-tooling: asdf-install

# Install asdf plugins
asdf-plugins tool_versions_dir="./":
    #!/bin/sh
    echo "Installing asdf plugins"
    for plugin in $(awk '{print $1}' {{tool_versions_dir}}.tool-versions); do \
      asdf plugin add ${plugin} 2>&1 | (grep "already added" && exit 0); \
    done

    echo "Update all asdf plugins"
    asdf plugin update --all

# Install tools using asdf
asdf-install: asdf-plugins
    asdf install

# Install tooling of the current dir (https://just.systems/man/en/working-directory.html)
[no-cd]
install-tooling-current-dir: asdf-install-current-dir

[no-cd]
asdf-install-current-dir:
    #!/bin/sh
    just asdf-plugins "$(pwd)/"
    asdf install
