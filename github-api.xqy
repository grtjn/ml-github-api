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
  let $file := github:http-get-text(concat($file-base, "README.md")) (: 7 mln counts on google :)
  let $file :=
    if ($file) then
      $file
    else
      github:http-get-text(concat($file-base, "README.rst")) (: 17 k counts on google :)
  return
    if ($file) then
      $file
    else
      github:http-get-text(concat($file-base, "README.mdown")) (: 7 k counts on google :)
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

(: Used for getting raw json files from github. Github returns them as text/plain,
   so we need to convert to json object ourselves.. :)
declare private function github:http-get-json($url as xs:string) as object-node()? {
  xdmp:unquote((github:http-get-text($url), "")[1])/object-node()
};

declare private function github:http-get-text($url as xs:string) as text()? {
  github:http-get($url)/text()
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


