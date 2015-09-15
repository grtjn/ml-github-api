# ml-github-api

MarkLogic library for querying the Github API.

NOTE: pretty much only covers repos search so far, but could be a useful start to build out. PR's welcome!

## Install

Installation depends on the [MarkLogic Package Manager](https://github.com/joemfb/mlpm):

```
$ mlpm install ml-github-api --save
$ mlpm deploy
```

## Usage

The usage of this library is shown below with a working code example. Note that running below code could take a minute or 10, and does inserts into your database:

```xquery
xquery version "1.0-ml";

import module namespace github = "http://marklogic.com/github-api" at "/ext/mlpm_modules/ml-github-api/github-api.xqy";

let $_ := github:set-oauth-keys("myclientid","myclientsecret")

let $users := map:map()

for $repo in
  github:search-repos("marklogic%20in:name,description,readme%20fork:false")

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

let $wrapped := object-node {
  "repo": $repo,
  "readme":  if ($readme)  then $readme  else null-node{},
  "license": if ($license) then $license else null-node{},
  "package": if ($package) then $package else null-node{},
  "bower":   if ($bower)   then $bower   else null-node{},
  "mlpm":    if ($mlpm)    then $mlpm    else null-node{},
  "user":    if ($user)    then $user    else null-node{},
  "type":
    if ($mlpm) then
      "mlpm"
    else if ($bower) then
      "bower"
    else if ($package) then
      "npm"
    else
      "other"
}

let $repo-uri := concat("/", $repo/full_name, ".json")
return
  xdmp:document-insert($repo-uri, $wrapped)
```
