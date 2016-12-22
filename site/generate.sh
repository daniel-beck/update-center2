#!/bin/bash -ex
# used from ci.jenkins-ci.org to actually generate the production OSS update center

# Used later for rsyncing updates
UPDATES_SITE="updates.jenkins.io"
RSYNC_USER="www-data"
declare -a BASELINES=( 1.554 1.565 1.580 1.596 1.609 1.625 1.642 1.651 2.7 2.19 2.32 )

umask

# prepare the www workspace for execution
rm -rf www2 || true
mkdir www2

mvn -e clean install

function generate() {
    java -jar target/update-center2-*-bin*/update-center2-*.jar \
      -id default \
      -connectionCheckUrl http://www.google.com/ \
      -key $SECRET/update-center.key \
      -certificate $SECRET/update-center.cert \
      "$@"
}

function sanity-check() {
    dir="$1"
    file="$dir/update-center.json"
    if [ 800000 -ge $(wc -c "$file" | cut -f 1 -d ' ') ]; then
        echo $file looks too small
        exit 1
    fi
}

# generate several update centers for different segments
# so that plugins can aggressively update baseline requirements
# without strnding earlier users.
#
# we use LTS as a boundary of different segments, to create
# a reasonable number of segments with reasonable sizes. Plugins
# tend to pick LTS baseline as the required version, so this works well.
#
# Looking at statistics like http://stats.jenkins-ci.org/jenkins-stats/svg/201409-jenkins.svg,
# I think three or four should be sufficient
#
# make sure the latest baseline version here is available as LTS and in the Maven index of the repo,
# otherwise it'll offer the weekly as update to a running LTS version


HTACCESS=htaccess-versions
echo "# Version-specific rulesets generated by generate.sh" > ${HTACCESS}

for v in ${BASELINES[@]}; do
    # for mainline up to $v, which advertises the latest core
    generate -no-experimental -skip-release-history -www ./www2/$v -cap $v.999 -capCore 2.999
    sanity-check ./www2/$v
    ln -sf ../updates ./www2/$v/updates

    # for LTS
    generate -no-experimental -skip-release-history -www ./www2/stable-$v -cap $v.999 -capCore ${BASELINES[${#BASELINES[@]}-1]}.999
    sanity-check ./www2/stable-$v
    ln -sf ../updates ./www2/stable-$v/updates
    lastLTS=$v

    # Split our version up into an array for rewriting
    # 1.651 becomes (1 651)
    versionPieces=(${v//./ })
    major=${versionPieces[0]}
    minor=${versionPieces[1]}
    cat <<EOF >>$HTACCESS

RewriteCond %{QUERY_STRING} ^.*version=${major}\.(\d+)$ [NC]
RewriteCond %1 <=${minor}
RewriteRule ^update\-center.*\.[json|html]+ /${major}\.${minor}%{REQUEST_URI}? [NC,L,R=301]
EOF

done


# Add a RewriteRule for the last LTS we have, which should always rewrite to
# /stable
cat <<EOF >>$HTACCESS

RewriteRule ^stable/(.+) "/stable-${lastLTS}/\$1" [NC,L,R=301]
EOF


# On generating http://mirrors.jenkins-ci.org/plugins layout
#     this directory that hosts actual bits need to be generated by combining both experimental content and current content,
#     with symlinks pointing to the 'latest' current versions. So we generate exprimental first, then overwrite current to produce proper symlinks

# experimental update center. this is not a part of the version-based redirection rules
generate -skip-release-history -www ./www2/experimental -download ./download
ln -sf ../updates ./www2/experimental/updates

# for the latest without any cap
# also use this to generae https://updates.jenkins-ci.org/download layout, since this generator run
# will capture every plugin and every core
generate -no-experimental -www ./www2/current -www-download ./www2/download -download ./download -pluginCount.txt ./www2/pluginCount.txt
ln -sf ../updates ./www2/current/updates

# generate symlinks to retain compatibility with past layout and make Apache index useful
pushd www2
    ln -s stable-$lastLTS stable
    for f in latest latestCore.txt release-history.json update-center.*; do
        ln -s current/$f .
    done

    # copy other static resource files
    rsync -avz "../site/static/" ./

    # Rewrite our generated .htaccess containing our version rules
    htaccess=$(<.htaccess)
    generated=$(<../${HTACCESS})
    echo "${htaccess//##LEGACY_UPDATECENTERS_TOKEN##/$generated}" > .htaccess
popd


# push plugins to mirrors.jenkins-ci.org
chmod -R a+r download
rsync -avz --size-only download/plugins/ ${RSYNC_USER}@${UPDATES_SITE}:/srv/releases/jenkins/plugins

# push generated index to the production servers
# 'updates' come from tool installer generator, so leave that alone, but otherwise
# delete old sites
chmod -R a+r www2
rsync -acvz www2/ --exclude=/updates --delete ${RSYNC_USER}@${UPDATES_SITE}:/var/www/${UPDATES_SITE}
