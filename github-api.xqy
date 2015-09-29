xquery version "1.0-ml";

module namespace github = "http://marklogic.com/github-api";

declare default function namespace "http://www.w3.org/2005/xpath-functions";

declare option xdmp:mapping "false";

declare private variable $client-id := ();
declare private variable $client-secret := ();

declare private variable $http-options :=
  <o:options xmlns:o="xdmp:http-get" xmlns="xdmp:document-get">
    <encoding>auto</encoding>
    <repair>full</repair>
  </o:options>
;

declare function github:set-oauth-keys($id, $secret) {
  xdmp:set($client-id, $id),
  xdmp:set($client-secret, $secret)
};

declare function github:search-repos($q as xs:string) as object-node()* {
  let $items := map:map()
  
  (: get rid of duplicates :)
  let $_ :=
    for $item in github:search-repos($q, 1)
    return map:put($items, $item/full_name, $item)
  
  for $name in map:keys($items)
  return map:get($items, $name)
};

declare private function github:search-repos($q as xs:string, $page as xs:int) as object-node()* {
  let $_ := xdmp:log(concat("Github repo search for ", $q, " page ", $page, ".."))
  let $result :=
    github:http-get(
      concat("https://api.github.com/search/repositories?q=", $q, "&amp;per_page=100&amp;page=", $page)
    )/object-node()
  let $total := data($result/total_count)
  let $incomplete := data($result/incomplete_results)
  let $repos := $result/items
  return (
    $repos,
    if ($incomplete or empty($repos)) then
      let $_ := xdmp:log(concat("Incomplete response, 10 sec courtesy sleep before retrying.."))
      let $_ := xdmp:sleep(10000) (: 10 sec courtesy sleep.. :)
      return
        github:search-repos($q, $page)
    else if (($page * 100) lt $total) then
      github:search-repos($q, $page + 1)
    else ()
  )
};

declare function github:get-readme($repo as object-node()) as text()? {
  let $file-base := github:file-base($repo)
  let $extensions := (
    ".md", (: 7 mln counts on google :)
    "", (: 1.7 mln counts on google :)
    ".txt", (: 470 k counts on google :)
    ".markdown", (: 85 k counts on google :)
    ".ext", (: 55 k counts on google :)
    ".textile", (: 22 k counts on google :)
    ".rst", (: 17 k counts on google :)
    ".mdown", (: 7 k counts on google :)
    ".adoc" (: 7 k counts on google :)
  )
  let $files := (
    $extensions ! concat($file-base, "README", .),
    $extensions ! concat($file-base, "readme", .)
  )
  return github:http-get-text($files)
};

declare function github:get-package($repo as object-node()) as object-node()? {
  github:http-get-json(
    concat(github:file-base($repo), "package.json")
  )
};

declare function github:get-bower($repo as object-node()) as object-node()? {
  github:http-get-json(
    concat(github:file-base($repo), "bower.json")
  )
};

declare function github:get-mlpm($repo as object-node()) as object-node()? {
  github:http-get-json(
    concat(github:file-base($repo), "mlpm.json")
  )
};

declare function github:get-user($name as xs:string) as object-node()? {
  let $_ := xdmp:log(concat("Getting github user ", $name, ".."))
  return
    github:http-get(
      concat("https://api.github.com/users/", $name)
    )/object-node()
};

(: Used for getting raw json files from github. Github returns them as text/plain,
   so we need to convert to json object ourselves.. :)
declare private function github:http-get-json($url as xs:string) as object-node()? {
  let $text := github:http-get-text($url)
  where $text
  return xdmp:unquote($text)/object-node()
};

declare private function github:http-get-text($urls as xs:string*) as text()? {
  let $text := github:http-get($urls[1])/text()
  return
    if ($text) then
      $text
    else if ($urls[2]) then
      github:http-get-text(subsequence($urls, 2))
    else ()
};

declare private function github:http-get($url as xs:string) as document-node()? {
  let $sleep := xdmp:sleep(100) (: 100 msec courtesy sleep.. :)
  let $response :=
    try {
      if (starts-with($url, "https://api.github.com") and $client-id and $client-secret) then
        let $url :=
          concat($url, if (contains($url, "?")) then "&amp;" else "?", "client_id=", $client-id, "&amp;client_secret=", $client-secret)
        return
          xdmp:http-get($url, $http-options)
      else
        xdmp:http-get($url, $http-options)
    } catch ($error) {
      xdmp:log($error)
    }
  return
    if ($response[1]//*:x-ratelimit-remaining = 0) then
      (: rate limit reached, sleep till reset time, to make sure we won't exceed the limit.. :)
      let $now-utc := (current-dateTime() - xs:dateTime("1970-01-01T00:00:00")) div xs:dayTimeDuration("PT1S")
      let $sec-until-reset := xs:unsignedInt(number($response[1]//*:x-ratelimit-reset) - $now-utc)
      let $_ := xdmp:log(concat("Rate limit reached, sleeping for ", $sec-until-reset, " sec.."))
      let $_ := xdmp:sleep($sec-until-reset * 1000)
      return
        $response[2]
    else
      $response[2]
};

declare private function github:file-base($repo as object-node()) as xs:string {
  let $full_name := data($repo/full_name)
  return concat("https://raw.githubusercontent.com/", $full_name, "/master/")
};

declare function github:get-normalized-license($package as object-node()*) as xs:string? {
  let $license := ($package/license)[1]/string()
  where $license
  return
    if (matches($license, "apache", "i") and contains($license, "2")) then
      "Apache-v2.0"
    else
      $license
};

