// HTTP client redirects
import std/async
import std/async/os/net
import std/async/os/http

fun show-res( r : http-response ) : string
  r.status.show ++ " " ++ r.body-text

fun main()
  val other = tcp-listen("127.0.0.1", 0)
  val other-base = "http://127.0.0.1:" ++ other.local-port.show
  val server = tcp-listen("127.0.0.1", 0)
  val base = "http://127.0.0.1:" ++ server.local-port.show
  // reports what a request looked like after redirection
  fun inspect( req : http-request ) : <async,exn,ndet> http-response
    text-response(200, req.method ++ " " ++ req.target ++ " body=" ++ req.body-text.show
                       ++ " auth=" ++ req.header("Authorization").default("-")
                       ++ " type=" ++ req.header("Content-Type").default("-"))
  fun route( req : http-request ) : <async,exn,ndet> http-response
    match req.path
      "/inspect" -> inspect(req)
      "/found"   -> text-response(302, "", [("Location", "/inspect?from=found")])
      "/see"     -> text-response(303, "", [("Location", "inspect?from=see")])
      "/temp"    -> text-response(307, "", [("Location", base ++ "/inspect?from=temp")])
      "/perm"    -> text-response(308, "", [("Location", "/inspect")])
      "/chain"   -> text-response(301, "", [("Location", "/found")])
      "/away"    -> text-response(302, "", [("Location", other-base ++ "/inspect")])
      "/loop"    -> text-response(302, "", [("Location", "/loop")])
      "/noloc"   -> text-response(302, "no location")
      _ -> text-response(404, "no route for " ++ req.path)
  val auth = [("Authorization", "secret")]
  fun requests()
    [ http-get(base ++ "/found").show-res,
      http-get(base ++ "/chain").show-res,
      http-post(base ++ "/found", "data".bytes, "text/plain").show-res,
      http-post(base ++ "/see", "data".bytes, "text/plain").show-res,
      http-post(base ++ "/temp", "data".bytes, "text/plain").show-res,
      http-request("PUT", base ++ "/perm", [("Content-Type", "text/plain")], "data".bytes).show-res,
      http-get(base ++ "/found", auth).show-res,
      http-get(base ++ "/away", auth).show-res,
      http-get(base ++ "/found", max-redirects = 0).status.show ++ " " ++ http-get(base ++ "/found", max-redirects = 0).header("Location").default(""),
      catch(fn(e) e.message, { http-get(base ++ "/chain", max-redirects = 1).show-res }),
      http-get(base ++ "/noloc").show-res,
      catch(fn(e) e.message, { http-get(base ++ "/loop").show-res }) ]
  val results = firstof({ http-serve(server, route); [] }) {
    firstof({ http-serve(other, inspect); [] }, requests)
  }
  results.foreach(println)
  server.close
  other.close

