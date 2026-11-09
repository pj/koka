// TLS server name indication: the server picks its certificate by the name
// the client asks for. Test certificates valid until 2126 (see the end).
import std/async
import std/async/os/net
import std/async/os/tls

val ca-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBnTCCAUOgAwIBAgIUcpMdxHMpL2+rqTZyv4HcZ/JhX2kwCgYIKoZIzj0EAwIw\n"
  ++ "GzEZMBcGA1UEAwwQS29rYSBTTkkgVGVzdCBDQTAgFw0yNjExMDkwMzQ4MDlaGA8y\n"
  ++ "MTI2MTAxNjAzNDgwOVowGzEZMBcGA1UEAwwQS29rYSBTTkkgVGVzdCBDQTBZMBMG\n"
  ++ "ByqGSM49AgEGCCqGSM49AwEHA0IABFYHYkjb+Ibc0sT9kBW1+Bo1RfmKnwJvmqgi\n"
  ++ "lt4p6DIgh5ykx/EKCOg5qDVZyoRb8jCxELuLQJ2nxN8KOdj4fbyjYzBhMB0GA1Ud\n"
  ++ "DgQWBBQdC1rF/aLk2s3eZ9dM6gK4a6sUPzAfBgNVHSMEGDAWgBQdC1rF/aLk2s3e\n"
  ++ "Z9dM6gK4a6sUPzAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwICBDAKBggq\n"
  ++ "hkjOPQQDAgNIADBFAiEA8Z5BoJ2V3CO/DyHnA0htTFRpyjILCrqIIXA6dueDx6QC\n"
  ++ "IBQFAh/P6XNHScJjccM02JpHg8byjHMkOsPTbphK7wK6\n"
  ++ "-----END CERTIFICATE-----\n"

val default-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBvTCCAWSgAwIBAgIURmA2jEXL6VXQurAMKhjpsws9M3kwCgYIKoZIzj0EAwIw\n"
  ++ "GzEZMBcGA1UEAwwQS29rYSBTTkkgVGVzdCBDQTAgFw0yNjExMDkwMzQ4MDlaGA8y\n"
  ++ "MTI2MTAxNjAzNDgwOVowEjEQMA4GA1UEAwwHZGVmYXVsdDBZMBMGByqGSM49AgEG\n"
  ++ "CCqGSM49AwEHA0IABFt/4aWaed9TzxnsvUfwgy6d5DM5CeAUB4U5CHqiVLHGEso1\n"
  ++ "Dh0gqf5kuX/06guY16Z6CHZEy3NSPdraa/K26dSjgYwwgYkwGgYDVR0RBBMwEYIJ\n"
  ++ "bG9jYWxob3N0hwR/AAABMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQM\n"
  ++ "MAoGCCsGAQUFBwMBMB0GA1UdDgQWBBSgrxcNW23D3n5CjLPiAH+AmKzHXjAfBgNV\n"
  ++ "HSMEGDAWgBQdC1rF/aLk2s3eZ9dM6gK4a6sUPzAKBggqhkjOPQQDAgNHADBEAiA8\n"
  ++ "bDAKg6kWL/OqEDhiFH+Od4XU+ULiwf+ptlr85YpmSwIgJojyP2DS0i8n3Gv0rvVk\n"
  ++ "nzRgL4576hX1X7TPBxAysVA=\n"
  ++ "-----END CERTIFICATE-----\n"

val default-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgSABaNURXrWu/c/hO\n"
  ++ "x/RMw7MWw8Fy8i/GffpCcV+cxnGhRANCAARbf+GlmnnfU88Z7L1H8IMuneQzOQng\n"
  ++ "FAeFOQh6olSxxhLKNQ4dIKn+ZLl/9OoLmNemegh2RMtzUj3a2mvytunU\n"
  ++ "-----END PRIVATE KEY-----\n"

val alpha-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBtjCCAV2gAwIBAgIURmA2jEXL6VXQurAMKhjpsws9M3owCgYIKoZIzj0EAwIw\n"
  ++ "GzEZMBcGA1UEAwwQS29rYSBTTkkgVGVzdCBDQTAgFw0yNjExMDkwMzQ4MDlaGA8y\n"
  ++ "MTI2MTAxNjAzNDgwOVowEDEOMAwGA1UEAwwFYWxwaGEwWTATBgcqhkjOPQIBBggq\n"
  ++ "hkjOPQMBBwNCAAS6M/xCLAQsRmJSc2OLY/MlkV6eik/FObB2RckQFqNKvJOm2SNe\n"
  ++ "mvwuGOG4TyOOQjrnQXlSFm0Ay98AQaEsUyKxo4GHMIGEMBUGA1UdEQQOMAyCCmFs\n"
  ++ "cGhhLnRlc3QwCQYDVR0TBAIwADALBgNVHQ8EBAMCB4AwEwYDVR0lBAwwCgYIKwYB\n"
  ++ "BQUHAwEwHQYDVR0OBBYEFNltMO6Ts/01xMURWnUn+DM310b5MB8GA1UdIwQYMBaA\n"
  ++ "FB0LWsX9ouTazd5n10zqArhrqxQ/MAoGCCqGSM49BAMCA0cAMEQCIBN7/ZfnBynF\n"
  ++ "D/in/FwUOJG1C0zhwSZDTWwPU0prZorNAiA7TApcwLGsPidH71Kn1Jq/oMFx768g\n"
  ++ "QK5475Uc/356rQ==\n"
  ++ "-----END CERTIFICATE-----\n"

val alpha-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgjO3TrhZqdqCctNmo\n"
  ++ "OgB98XJ+egAQ7cukI54N5Knp6kuhRANCAAS6M/xCLAQsRmJSc2OLY/MlkV6eik/F\n"
  ++ "ObB2RckQFqNKvJOm2SNemvwuGOG4TyOOQjrnQXlSFm0Ay98AQaEsUyKx\n"
  ++ "-----END PRIVATE KEY-----\n"

val beta-cert = "-----BEGIN CERTIFICATE-----\n"
  ++ "MIIBtjCCAV2gAwIBAgIURmA2jEXL6VXQurAMKhjpsws9M3swCgYIKoZIzj0EAwIw\n"
  ++ "GzEZMBcGA1UEAwwQS29rYSBTTkkgVGVzdCBDQTAgFw0yNjExMDkwMzQ4MDlaGA8y\n"
  ++ "MTI2MTAxNjAzNDgwOVowDzENMAsGA1UEAwwEYmV0YTBZMBMGByqGSM49AgEGCCqG\n"
  ++ "SM49AwEHA0IABCcLi7eCgYKrMpLHZD/CM8pKK1Zk+BHXrOKn2i5TH+XL0IU0lo1c\n"
  ++ "1oHn5Ff8DaR17sjuxCVEAjozpI55g6eK8DSjgYgwgYUwFgYDVR0RBA8wDYILKi5i\n"
  ++ "ZXRhLnRlc3QwCQYDVR0TBAIwADALBgNVHQ8EBAMCB4AwEwYDVR0lBAwwCgYIKwYB\n"
  ++ "BQUHAwEwHQYDVR0OBBYEFH6oH/nijau8S4Hsa2OkxaDBOUiNMB8GA1UdIwQYMBaA\n"
  ++ "FB0LWsX9ouTazd5n10zqArhrqxQ/MAoGCCqGSM49BAMCA0cAMEQCIAMCuMwDTwTU\n"
  ++ "hMVhhnvpls8yyTUyNlt5s8QfmyCH077BAiAv2sFLlIl2A4s4GI5HOscDD5beXEH7\n"
  ++ "BH51hfMpRvVEXA==\n"
  ++ "-----END CERTIFICATE-----\n"

val beta-key = "-----BEGIN PRIVATE KEY-----\n"
  ++ "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg9sj448twejL1H/iK\n"
  ++ "EB8jCaBT0zqOaRKERPoLei5QT5uhRANCAAQnC4u3goGCqzKSx2Q/wjPKSitWZPgR\n"
  ++ "16zip9ouUx/ly9CFNJaNXNaB5+RX/A2kde7I7sQlRAI6M6SOeYOnivA0\n"
  ++ "-----END PRIVATE KEY-----\n"

// The subject of the certificate the server presented, connecting to 127.0.0.1 with `name`.
fun subject-for( port : int, name : string ) : <async,exn,net> string
  catch(fn(e) "rejected: " ++ (if e.message.contains("certificate") || e.message.contains("verif") || e.message.contains("CERT") || e.message.contains("altname") || e.message.contains("Hostname") then "certificate" else e.message)) fn()
    tls-connect("127.0.0.1", port, fn(s : net-stream) { s.write-text("hello"); s.read.string }, ca = ca-cert, server-name = name)

fun main()
  val config = tls-server-config(default-cert, default-key, sni = [("alpha.test", alpha-cert, alpha-key), ("*.beta.test", beta-cert, beta-key)])
  val srv = tcp-listen("127.0.0.1", 0)
  val port = srv.local-port
  val names = ["alpha.test", "ALPHA.test", "www.beta.test", "x.beta.test", "localhost", "beta.test", "a.b.beta.test"]
  val results = firstof({
    srv.serve fn(conn)
      val s = conn.tls-accept(config)
      val _ = s.read
      s.write-text("ok")
      s.close-notify
    []
  }, {
    names.map(fn(n) n ++ ": " ++ subject-for(port, n))
  })
  results.foreach(println)
  srv.close
  println(catch(fn(e) e.message.contains("SNI").show, { tls-server-config(default-cert, default-key, sni = [("x", "junk", "junk")]); "accepted" }))

/* The test certificates were made with:

   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 36500 \
     -subj "/CN=Koka SNI Test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
   and for each of default (DNS:localhost,IP:127.0.0.1), alpha (DNS:alpha.test) and beta (DNS:*.beta.test):
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $n.key -out $n.csr -subj "/CN=$n"
   printf "subjectAltName=$san\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n" > $n.cnf
   openssl x509 -req -in $n.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $n.pem -days 36500 -extfile $n.cnf
*/
