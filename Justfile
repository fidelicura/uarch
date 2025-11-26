JUST := just_executable()
OUT := "build"

set quiet

[private]
default:
	{{JUST}} --list --unsorted --no-aliases

clean:
    rm -rf {{OUT}}/

build NAME:
    #!/usr/bin/env bash
    pushd experiments/{{NAME}}
    just build "../../{{OUT}}"
    popd
