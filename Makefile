# This is a helper for infra
update-puppet:
	OLD_COMMIT=$$(grep scripts_rev ../puppet/dist/repo_mirror_ci/manifests/init.pp | cut -d"'" -f2 | head -n1); \
	NEW_COMMIT=$$(git rev-parse HEAD); \
	sed -i -e "/.scripts_rev = /s/$${OLD_COMMIT}/$${NEW_COMMIT}/" ../puppet/dist/repo_mirror_ci/manifests/init.pp; \
	{ printf "repo_mirror_ci: update\n\n" ; git shortlog $${OLD_COMMIT}..$${NEW_COMMIT} ; } | git -C ../puppet commit --signoff dist/repo_mirror_ci/manifests/init.pp -F -;
