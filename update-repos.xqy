xquery version "1.0-ml";

import module namespace github = "http://marklogic.com/github-api" at "/ext/mlpm_modules/ml-github-api/github-api.xqy";
import module namespace config = "http://marklogic.com/github-search/config" at "/app/config/config.xqy";

declare default function namespace "http://www.w3.org/2005/xpath-functions";

declare option xdmp:mapping "false";

declare variable $i external;
declare variable $repos external;
declare variable $last external;

xdmp:set-request-time-limit(1800), (: 30 min. :)

(: To use authenticated calls with increased rate limits:

 - Go to https://github.com/settings/developers
 - Register new application called `MarkLogic Github Search`
 - Copy client-id and client-secret, paste them in set-oauth-keys line below
 - Uncomment the following line:

let $_ := github:set-oauth-keys("##myclientid##","##myclientsecret##")
:)
let $_ :=
  if ($config:github-clientid != "" and $config:github-clientsecret != "") then
    github:set-oauth-keys($config:github-clientid, $config:github-clientsecret)
  else ()

let $repos :=
  try {
    json:array-values($repos)
  } catch ($ignore) {}
let $last :=
  try {
    $last
  } catch ($ignore) {
    false()
  }

return
  if ($repos) then
    (: process dispatch :)
    let $_ := xdmp:log(concat("Processing batch ", $i, ".."))
    let $_ :=
      let $users := map:map()
      for $repo in $repos

      let $gist := $repo/gist
      let $readme := if ($gist) then () else github:get-readme($repo)
      let $package := if ($gist) then () else github:get-package($repo)
      let $bower := if ($gist) then () else github:get-bower($repo)
      let $mlpm := if ($gist) then () else github:get-mlpm($repo)
      let $license := if ($gist) then () else github:get-normalized-license(($package, $bower, $mlpm))

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
          if ($gist) then
            "gist"
          else if ($mlpm and (empty($mlpm/private) or not($mlpm/private))) then
            "mlpm"
          else if ($bower and (empty($bower/private) or not($bower/private))) then
            "bower"
          else if ($package and (empty($package/private) or not($package/private))) then
            "npm"
          else
            "other",
        "readme": if ($readme) then $readme else null-node{},
        "license": if ($license) then $license else null-node{},
        "mlpm": if ($mlpm) then $mlpm else null-node{},
        "bower": if ($bower) then $bower else null-node{},
        "package": if ($package) then $package else null-node{},
        "repo": $repo,
        "user": if ($user) then $user else null-node{},
        "refreshed_at": string(current-dateTime())
      }

      let $uri := concat("/", $repo/full_name, ".json")
      let $_ :=
        xdmp:document-insert(
          $uri,
          $item,
          (xdmp:permission("github-search-role", "read"), xdmp:permission("github-search-role", "update")),
          ("data", "data/github")
        )
      return xdmp:log(concat("Batch ", $i, ": added ", $uri, ".."))
    let $_ := xdmp:log(concat("Done processing batch ", $i, " in ", xdmp:elapsed-time(), ".."))
    where $last
    return
      (: flush stale repositories :)
      let $recent := current-dateTime() - xs:dayTimeDuration("P7D") (: 1 week old :)
      for $repo in collection('data/github')
      let $refreshed := $repo/refreshed_at/xs:dateTime(.)
      where empty($refreshed) or $refreshed lt $recent
      return
        xdmp:document-delete(base-uri($repo))
  else
    (: search and dispatch :)
    let $repos :=
      for $repo in (
        github:search-repos("marklogic in:name,description,readme fork:false"),
        github:search-gists("marklogic anon:true")
      )
      order by $repo/full_name
      return $repo
    let $total := count($repos)
    let $batch-size := 100
    let $nr-batches := ceiling($total div $batch-size)

    let $_ :=
      for $i in (1 to $nr-batches)
      let $end := $batch-size * $i
      let $start := $end - $batch-size + 1
      let $batch := subsequence($repos, $batch-size * ($i - 1) + 1, $batch-size)
      let $_ := xdmp:log(concat("Spawning batch ", $i, ".."))
      return
        xdmp:spawn("update-repos.xqy", (xs:QName("repos"), json:to-array($batch), xs:QName("i"), $i, xs:QName("last"), $i eq $nr-batches))
    return
      xdmp:log(concat("Done spawning ", $nr-batches, " batches in ", xdmp:elapsed-time(), ".."))
