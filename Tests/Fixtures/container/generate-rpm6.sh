#!/bin/bash
# rpm 6.1.0 の black-box writer / oracle だけで生成する。
set -euo pipefail
export LC_ALL=en_US.UTF-8 TZ=UTC
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
rpm_work="$(mktemp -d /private/tmp/kaitokit-rpm6.XXXXXX)"
trap 'rm -rf "$rpm_work"' EXIT
mkdir -p "$rpm_work"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,rpmdb,keys,tmp}
rpmbuild --version
rpm --version
for variant in stripped-v6-zstd stripped-v6-gzip stripped-v4-gzip; do
    format=6
    set --
    case "$variant" in
        stripped-v6-zstd) ;;
        stripped-v6-gzip) set -- --define '_binary_payload w9.gzdio' ;;
        stripped-v4-gzip) format=4; set -- --define '_binary_payload w9.gzdio' ;;
    esac
    LC_ALL=C rpmbuild -bb --define "_topdir $rpm_work" --define "_tmppath $rpm_work/tmp" --define "_rpmformat $format" \
        --define '_buildhost kaitokit-fixture' --define "_dbpath $rpm_work/rpmdb" \
        --define "_keyringpath $rpm_work/keys" "$@" "$fixture_dir/rpm-stripped.spec"
    cp "$rpm_work/RPMS/noarch/kaito-rpm6-1.0-1.noarch.rpm" "$rpm_work/rpm-$variant.rpm"
done
python3 "$fixture_dir/record-rpm6.py" "$rpm_work" "$fixture_dir"
