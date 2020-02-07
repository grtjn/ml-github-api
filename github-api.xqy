xquery version "1.0-ml";

module namespace github = "http://marklogic.com/github-api";

declare namespace html = "http://www.w3.org/1999/xhtml";

declare default function namespace "http://www.w3.org/2005/xpath-functions";

declare option xdmp:mapping "false";

declare private variable $client-id := ();
declare private variable $client-secret := ();

(: BASIC auth is required now, generate options dynamically :)
(: https://developer.github.com/changes/2019-11-05-deprecated-passwords-and-authorizations-api/#authenticating-using-query-parameters :)
declare private function github:http-options() {
  <o:options xmlns:o="xdmp:http" xmlns="xdmp:document-get">
    <encoding>auto</encoding>
    <repair>full</repair>
    {
      if (exists($client-id) and exists($client-secret)) then
        <authentication xmlns="xdmp:http" method="basic">
          <username>{$client-id}</username>
          <password>{$client-secret}</password>
        </authentication>
      else ()
    }
  </o:options>
};

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
  let $_ := xdmp:log(concat("Github repo search for '", $q, "' page ", $page, ".."))
  let $page-size := 100
  let $result :=
    github:http-get(
      concat("https://api.github.com/search/repositories?sort=updated&amp;order=desc&amp;q=", encode-for-uri($q), "&amp;per_page=", $page-size, "&amp;page=", $page)
    )/object-node()
  let $incomplete := data($result/incomplete_results)
  let $repos := $result/items
  return (
    $repos,
    if ($incomplete) then
      let $_ := xdmp:log(concat("Incomplete response, 10 sec courtesy sleep before retrying.."))
      let $_ := xdmp:sleep(10000) (: 10 sec courtesy sleep.. :)
      return
        github:search-repos($q, $page)
    else if (count($repos) >= $page-size) then
      github:search-repos($q, $page + 1)
    else ()
  )
};

declare function github:search-gists($q as xs:string) as object-node()* {
  let $items := map:map()

  (: get rid of duplicates :)
  let $_ :=
    for $item in github:search-gists($q, 1)
    return map:put($items, $item/full_name, $item)

  for $name in map:keys($items)
  return map:get($items, $name)
};

declare private function github:search-gists($q as xs:string, $page as xs:int) as object-node()* {
  let $_ := xdmp:log(concat("Github gist search for '", $q, "' page ", $page, ".."))
  let $gists :=
    github:tidy-gist-search(
      github:http-get(
        concat("https://gist.github.com/search?q=", encode-for-uri($q), "&amp;p=", $page)
      )
    )
  return (
    $gists,
    if (exists($gists)) then
      github:search-gists($q, $page + 1)
    else ()
  )
};

declare private function github:tidy-gist-search($response) as object-node()* {
  if ($response) then
    (: There is not API call to search gists, so we need to work through HTML search instead.. :)
    for $gist in xdmp:tidy(
      $response,
      <options xmlns="xdmp:tidy">
        <new-inline-tags>time-ago time</new-inline-tags>
      </options>
    )[2]//html:div[@class = 'gist-snippet']

    (: Fragile, let's hope Github doesn't change the HTML of Gist search too often.. :)
    let $link := ($gist//html:a/@href)[1]
      let $owner := replace($link, "^/([^/]+)/([^/]+)$", "$1")
      let $id := replace($link, "^/([^/]+)/([^/]+)$", "$2")
    let $creator := normalize-space(($gist//html:span[@class = "creator"])[1])
      let $filename := substring-after($creator, " / ")
    let $snippet := string-join($gist//html:td[string(@class) = "blob-code blob-code-inner js-file-line"], "&#10;")
    let $description := normalize-space(($gist//html:span[@class = "description"])[1])
    let $created := string($gist//html:div[@class = 'extra-info' and starts-with(., 'Created')]/(html:time-ago, html:time)/@datetime)
    let $updated := string($gist//html:div[@class = 'extra-info' and starts-with(., 'Last')]/(html:time-ago, html:time)/@datetime)
    let $language := substring-after($gist//html:div[@class = 'blob-wrapper']/string(@class), 'type-')
    let $links := $gist//html:ul[@class = 'gist-count-links']//html:a
    let $size := number($links[contains(., 'file')]/substring-before(., 'file'))
    let $stars := number($links[contains(., 'star')]/substring-before(., 'star'))
    let $forks := number($links[contains(., 'fork')]/substring-before(., 'fork'))
    let $comments := number($links[contains(., 'comment')]/substring-before(., 'comment'))

    (: Close to the official gist structure. Just a few differences to make it look similar to repos.. :)
    return object-node{
      "gist": true(),
      "id": $id,
      "owner": object-node{
        "login": $owner
      },
      "name": $filename,
      "full_name": $owner || "/" || $filename,
      "snippet": $snippet,
      "description": $description,
      "public": true(),
      "html_url": "https://gist.github.com/" || $owner || "/" || $id,
      "embed_html": "<script src=""https://gist.github.com/" || $owner || "/" || $id || ".js""></script>",
      "created_at": ($created[. != ''], $updated)[1],
      "updated_at": ($updated[. != ''], $created)[1],
      "language": $language,
      "size": $size,
      "stargazers_count": $stars,
      "forks_count": $forks,
      "comments": $comments,
      "open_issues_count": $comments
    }
  else ()
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
  let $sleep := xdmp:sleep(250) (: 250 msec courtesy sleep.. :)
  let $response :=
    try {
      xdmp:http-get($url, github:http-options())
    } catch ($error) {
      xdmp:log((concat("Github get failed for ", $url, ":"), $error)) (: log error message :)
    }
  return
    if ($response[1]//*:x-ratelimit-remaining = 0) then
      (: rate limit reached, sleep till reset time to make sure we won't exceed the limit.. :)
      let $now-utc := (current-dateTime() - xs:dateTime("1970-01-01T00:00:00")) div xs:dayTimeDuration("PT1S")
      let $sec-until-reset := xs:unsignedInt(number($response[1]//*:x-ratelimit-reset) - $now-utc)
      let $_ := xdmp:log(concat("Rate limit reached, sleeping for ", $sec-until-reset, " sec.."))
      let $_ := xdmp:sleep(500 + $sec-until-reset * 1000)
      where $response[1]/*:code = 200
      return
        $response[2]
    else if ($response[1]/*:code = (429, 503)) then
      (: rate limit reached, sleep till retry-after time to make sure we won't exceed the limit.. :)
      let $sec-until-reset := xs:unsignedInt(number($response[1]//*:retry-after))
      let $_ := xdmp:log(concat("Overload, sleeping for ", $sec-until-reset, " sec.."))
      let $_ := xdmp:sleep(500 + $sec-until-reset * 1000)
      let $_ := xdmp:log(concat("Trying again.."))
      return
        github:http-get($url)
    else if ($response[1]/*:code = 200) then
      $response[2]
    else if ($response[1]/*:code = 404) then
      xdmp:log(concat("Not found: ", $url), "debug") (: log error message :)
    else if ($response) then
      xdmp:log((concat("Github get failed for ", $url, ":"), $response)) (: log error message :)
    else ()
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

