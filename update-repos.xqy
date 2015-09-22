xquery version "1.0-ml";

import module namespace github = "http://marklogic.com/github-api" at "/ext/mlpm_modules/ml-github-api/github-api.xqy";

declare default function namespace "http://www.w3.org/2005/xpath-functions";

declare option xdmp:mapping "false";

declare variable $i external;
declare variable $repos external;

xdmp:set-request-time-limit(1800), (: 30 min. :)

(: To use authenticated calls with increased rate limits:

 - Go to https://github.com/settings/developers
 - Register new application called `MarkLogic Github Search`
 - Copy client-id and client-secret, paste them in set-oauth-keys line below
 - Uncomment the following line:

let $_ := github:set-oauth-keys("##myclientid##","##myclientsecret##")
:)

let $repos :=
  try {
    $repos
  } catch ($ignore) {}

return
  if ($repos) then
    (: process dispatch :)
    let $_ := xdmp:log(concat("Processing batch ", $i, ".."))
    let $_ :=
      let $users := map:map()
      for $repo in json:array-values($repos)

      let $readme := github:get-readme($repo)
      let $package := github:get-package($repo)
      let $bower := github:get-bower($repo)
      let $mlpm := github:get-mlpm($repo)
      let $license := github:get-normalized-license(($package, $bower, $mlpm))

      let $owner := $repo/owner/login
      let $user := map:get($users, $owner)
      let $user :=
        if ($user) then
          $user
        else
          let $user := github:get-user($owner)
          let $_ := map:put($users, $owner, $user)
          return $user

      let $item := object-node {
        "type":
          if ($mlpm) then
            "mlpm"
          else if ($bower) then
            "bower"
          else if ($package) then
            "npm"
          else
            "other",
        "readme": if ($readme) then $readme else null-node{},
        "license": if ($license) then $license else null-node{},
        "mlpm": if ($mlpm) then $mlpm else null-node{},
        "bower": if ($bower) then $bower else null-node{},
        "package": if ($package) then $package else null-node{},
        "repo": $repo,
        "user": if ($user) then $user else null-node{}
      }

      return
        xdmp:document-insert(
          concat("/", $repo/full_name, ".json"),
          $item,
          (xdmp:permission("github-search-role", "read"), xdmp:permission("github-search-role", "update")),
          ("data", "data/github")
        )
    let $_ := xdmp:log(concat("Done processing batch ", $i, ".."))
    return
      xdmp:elapsed-time()
  else
    (: search and dispatch :)
    let $repos := github:search-repos("marklogic%20in:name,description,readme%20fork:false")
    let $total := count($repos)
    let $batch-size := 100
    let $nr-batches := ceiling($total div $batch-size)

    for $i in (1 to $nr-batches)
    let $end := $batch-size * $i
    let $start := $end - $batch-size + 1
    let $batch := subsequence($repos, $batch-size * ($i - 1) + 1, $batch-size)
    let $_ := xdmp:log(concat("Spawning batch ", $i, ".."))
    return
      xdmp:spawn("update-repos.xqy", (xs:QName("repos"), json:to-array($batch), xs:QName("i"), $i))
