xquery version "1.0-ml";

module namespace github = "http://marklogic.com/github-api";

declare default function namespace "http://www.w3.org/2005/xpath-functions";

declare option xdmp:mapping "false";

declare private variable $http-options :=
  <o:options xmlns:o="xdmp:http-get" xmlns="xdmp:document-get">
    <encoding>auto</encoding>
    <repair>full</repair>
  </o:options>
;

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
      let $sleep := xdmp:sleep(18000) (: 18 sec, likely exceeded rate limit :)
      return
        github:search-repos($q, $page)
    else if (($page * 100) lt $total) then
      let $sleep := xdmp:sleep(6000) (: 6 sec, guest rate limit is 10 req/minute :)
      return
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
    ".rst", (: 17 k counts on google :)
    ".mdown" (: 7 k counts on google :)
  )
  let $files := $extensions ! concat($file-base, "README", .)
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
  try {
    xdmp:http-get($url, $http-options)[2]
  } catch ($error) {
    xdmp:log($error)
  }
};

declare private function github:file-base($repo as object-node()) as xs:string {
  let $full_name := data($repo/full_name)
  return concat("https://raw.githubusercontent.com/", $full_name, "/master/")
};


