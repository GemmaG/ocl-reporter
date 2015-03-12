open Feeds
open Nethtml
open Syndic
open Printf
open Bootstrap

type html = Nethtml.document list

(** Our representation of a "post". *)
type post = {
  title : string;
  link  : Uri.t option;
  date  : Syndic.Date.t option;
  contributor : contributor;
  author : string;
  email : string;
  desc  : html;
}

(* Utils
 ***********************************************************************)

let rec length_html html =
  List.fold_left (fun l h -> l + length_html_el h) 0 html
and length_html_el = function
  | Element(_, _, content) -> length_html content
  | Data d -> String.length d

let rec len_prefix_of_html html len =
  if len <= 0 then 0, []
  else match html with
       | [] -> len, []
       | el :: tl -> let len, prefix_el = len_prefix_of_el el len in
                    let len, prefix_tl = len_prefix_of_html tl len in
                    len, prefix_el :: prefix_tl
and len_prefix_of_el el len =
  match el with
  | Data d ->
     let len' = len - String.length d in
     len', (if len' >= 0 then el else Data(String.sub d 0 len ^ "…"))
  | Element(tag, args, content) ->
     (* Remove "id" and "name" to avoid duplicate anchors with the
        whole post. *)
     let args = List.filter (fun (n,_) -> n <> "id" && n <> "name") args in
     let len, prefix_content = len_prefix_of_html content len in
     len, Element(tag, args, prefix_content)

let rec prefix_of_html html len =
  snd(len_prefix_of_html html len)

let date_of_post p =
  match p.date with
  | None -> "<Date Unknown>"
  | Some d ->
       let open Syndic.Date in
       sprintf "%s %02d, %d" (string_of_month(month d)) (day d) (year d)

let rec filter_map l f =
  match l with
  | [] -> []
  | a :: tl -> match f a with
              | None -> filter_map tl f
              | Some a -> a :: filter_map tl f

let new_id =
  let id = ref 0 in
  fun () -> incr id; sprintf "ocamlorg-post%i" !id

(* [toggle html1 html2] return some piece of html with buttons to pass
   from [html1] to [html2] and vice versa. *)
let toggle ?(anchor="") html1 html2 =
  let button id1 id2 text =
    Element("a", ["onclick", sprintf "switchContent('%s','%s')" id1 id2;
                  "class", "btn planet-toggle";
                  "href", "#" ^ anchor],
            [Data text])
  in
  let id1 = new_id() and id2 = new_id() in
  [Element("div", ["id", id1],
           html1 @ [button id1 id2 "Read more..."]);
   Element("div", ["id", id2; "style", "display: none"],
           html2 @ [button id2 id1 "Hide"])]

let toggle_script =
  let script =
    "function switchContent(id1,id2) {
     // Get the DOM reference
     var contentId1 = document.getElementById(id1);
     var contentId2 = document.getElementById(id2);
     // Toggle
     contentId1.style.display = \"none\";
     contentId2.style.display = \"block\";
     }\n" in
  [Element("script", ["type", "text/javascript"], [Data script])]

let encode_html =
  Netencoding.Html.encode ~prefer_name:false ~in_enc:`Enc_utf8 ()

let decode_document html = Nethtml.decode ~enc:`Enc_utf8 html

let encode_document html = Nethtml.encode ~enc:`Enc_utf8 html

let rec resolve ?xmlbase html =
  List.map (resolve_links_el ~xmlbase) html
and resolve_links_el ~xmlbase = function
  | Nethtml.Element("a", attrs, sub) ->
     let attrs = match List.partition (fun (t,_) -> t = "href") attrs with
       | [], _ -> attrs
       | (_, h) :: _, attrs ->
          let src = Uri.to_string(XML.resolve xmlbase (Uri.of_string h)) in
          ("href", src) :: attrs in
     Nethtml.Element("a", attrs, resolve ?xmlbase sub)
  | Nethtml.Element("img", attrs, sub) ->
     let attrs = match List.partition (fun (t,_) -> t = "src") attrs with
       | [], _ -> attrs
       | (_, src) :: _, attrs ->
          let src = Uri.to_string(XML.resolve xmlbase (Uri.of_string src)) in
          ("src", src) :: attrs in
     Nethtml.Element("img", attrs, sub)
  | Nethtml.Element(e, attrs, sub) ->
     Nethtml.Element(e, attrs, resolve ?xmlbase sub)
  | Data _ as d -> d


(* Things that posts should not contain *)
let undesired_tags = ["style"; "script"]
let undesired_attr = ["id"]

let remove_undesired_attr =
  List.filter (fun (a,_) -> not(List.mem a undesired_attr))

let rec remove_undesired_tags html =
  filter_map html remove_undesired_tags_el
and remove_undesired_tags_el = function
  | Nethtml.Element(t, a, sub) ->
     if List.mem t undesired_tags then None
     else Some(Nethtml.Element(t, remove_undesired_attr a,
                               remove_undesired_tags sub))
  | Data _ as d -> Some d

let relaxed_html40_dtd =
  (* Allow <font> inside <pre> because blogspot uses it! :-( *)
  let constr = `Sub_exclusions([ "img"; "object"; "applet"; "big"; "small";
                                 "sub"; "sup"; "basefont"],
                               `Inline) in
  let dtd = Nethtml.relaxed_html40_dtd in
  ("pre", (`Block, constr)) :: List.remove_assoc "pre" dtd

let html_of_text ?xmlbase s =
  try Nethtml.parse (new Netchannels.input_string s)
                    ~dtd:relaxed_html40_dtd
      |> decode_document
      |> resolve ?xmlbase
      |> remove_undesired_tags
  with _ ->
    [Nethtml.Data(encode_html s)]

(* Do not trust sites using XML for HTML content.  Convert to string
   and parse back.  (Does not always fix bad HTML unfortunately.) *)
let rec html_of_syndic =
  let ns_prefix _ = Some "" in
  fun ?xmlbase h ->
  html_of_text ?xmlbase
               (String.concat "" (List.map (XML.to_string ~ns_prefix) h))



let string_of_option = function None -> "" | Some s -> s

(* Email on the forge contain the name in parenthesis *)
let forge_name_re =
  Str.regexp ".*(\\([^()]*\\))"

let post_compare p1 p2 =
  (* Most recent posts first.  Posts with no date are always last *)
  match p1.date, p2.date with
  | Some d1, Some d2 -> Syndic.Date.compare d2 d1
  | None, Some _ -> 1
  | Some _, None -> -1
  | None, None -> 1

let rec remove n l =
  if n <= 0 then l
  else match l with [] -> []
                  | _ :: tl -> remove (n - 1) tl

let rec take n = function
  | [] -> []
  | e :: tl -> if n > 0 then e :: take (n-1) tl else []

(* Blog feed
 ***********************************************************************)

let post_of_atom ~contributor (e: Atom.entry) =
  let open Atom in
  let link = try Some (List.find (fun l -> l.rel = Alternate) e.links).href
             with Not_found -> match e.links with
                              | l :: _ -> Some l.href
                              | [] -> None in
  let date = match e.published with
    | Some _ -> e.published
    | None -> Some e.updated in
  let desc = match e.content with
    | Some(Text s) -> html_of_text s
    | Some(Html(xmlbase, s)) -> html_of_text ?xmlbase s
    | Some(Xhtml(xmlbase, h)) -> html_of_syndic ?xmlbase h
    | Some(Mime _) | Some(Src _)
    | None ->
       match e.summary with
       | Some(Text s) -> html_of_text s
       | Some(Html(xmlbase, s)) -> html_of_text ?xmlbase s
       | Some(Xhtml(xmlbase, h)) -> html_of_syndic ?xmlbase h
       | None -> [] in
  let author, _ = e.authors in
  { title = string_of_text_construct e.title;
    link;  date; contributor; author = author.name;
    email = ""; desc }

let post_of_rss2 ~(contributor: contributor) it =
  let open Syndic.Rss2 in
  let title, desc = match it.story with
    | All (t, xmlbase, d) ->
       t, (match it.content with
           | (_, "") -> html_of_text ?xmlbase d
           | (xmlbase, c) -> html_of_text ?xmlbase c)
    | Title t -> t, []
    | Description(xmlbase, d) ->
       "", (match it.content with
            | (_, "") -> html_of_text ?xmlbase d
            | (xmlbase, c) -> html_of_text ?xmlbase c) in
  let link = match it.guid, it.link with
    | Some u, _ when u.permalink -> Some u.data
    | _, Some _ -> it.link
    | Some u, _ ->
       (* Sometimes the guid is indicated with isPermaLink="false" but
          is nonetheless the only URL we get (e.g. ocamlpro). *)
       Some u.data
    | None, None -> None in
  { title; link; contributor; author = contributor.name;
    email = string_of_option it.author; desc; date = it.pubDate }

let posts_of_contributor c =
  match c.feed with
  | Atom f -> List.map (post_of_atom ~contributor:c) f.Atom.entries
  | Rss2 ch -> List.map (post_of_rss2 ~contributor:c) ch.Rss2.items
  | Broken _ -> []


let get_posts ?n ?(ofs=0) planet_feeds =
  let posts = List.concat @@ List.map posts_of_contributor planet_feeds in
  let posts = List.sort post_compare posts in
  let posts = remove ofs posts in
  match n with
  | None -> posts
  | Some n -> take n posts

let write_posts ?num_posts ?ofs ~file planet_feeds =
  let posts = get_posts ?n:num_posts ?ofs planet_feeds in
  let recentList = List.map (fun p ->
                     let date = date_of_post p in
                     let title = p.title in
                     let url = match p.link with
                       | Some u -> Uri.to_string u
                       | None -> Digest.to_hex (Digest.string (p.title)) in
                     let author = p.author in
                     mk_recent date url author title) posts in
  let postList = List.map (fun p ->
                   let title = p.title in
                   let date = date_of_post p in
                   let url = match p.link with
                     | Some u -> Uri.to_string u
                     | None -> Digest.to_hex (Digest.string (p.title)) in
                   let author = p.author in
                   let blog_name = p.contributor.name in
                   let blog_title = p.contributor.title in
                   let blog_url = p.contributor.url in
                   let face = p.contributor.face in
                   let face_height = p.contributor.face_height in
                   (* Write contents *)
                   let buffer = Buffer.create 0 in
                   let channel = new Netchannels.output_buffer buffer in
                   let desc = if length_html p.desc < 1000 then p.desc
                              else toggle (prefix_of_html p.desc 1000) p.desc ~anchor:url in
                   let _ = Nethtml.write channel @@ encode_document desc in
                   let content = Buffer.contents buffer in
                   match face with
                     | None -> mk_post url title blog_url blog_title blog_name
                                       author date content
                     | Some face -> mk_post_with_face url title blog_url
                                      blog_title blog_name author date
                                      content face face_height)
                  posts in
  let body = mk_body (String.concat "\n" recentList)
                     (String.concat "\n<br/><br/><br/>\n" postList) in
  (* write to file *)
  let f = open_out file in
  let () = output_string f body in
  close_out f

