#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
distribution_directory="${repository_root}/dist"
application_directory="${distribution_directory}/MagicDock.app"
contents_directory="${application_directory}/Contents"
macos_directory="${contents_directory}/MacOS"

cd "${repository_root}"

swift build -c release --product MagicDock
binary_directory="$(swift build -c release --show-bin-path)"

if [[ "${application_directory}" != "${repository_root}/dist/MagicDock.app" ]]; then
    print -u2 "Refusing to package an unexpected path: ${application_directory}"
    exit 1
fi

rm -rf -- "${application_directory}"
mkdir -p "${macos_directory}"
cp "${binary_directory}/MagicDock" "${macos_directory}/MagicDock"
cp "${repository_root}/Config/Info.plist" "${contents_directory}/Info.plist"

signing_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --options runtime --sign "${signing_identity}" "${application_directory}"
codesign --verify --deep --strict --verbose=2 "${application_directory}"

archive_path="${distribution_directory}/MagicDock-0.1.0.zip"
rm -f -- "${archive_path}"
ditto -c -k --norsrc --noextattr --keepParent "${application_directory}" "${archive_path}"

print "Built ${application_directory}"
print "Archived ${archive_path}"
