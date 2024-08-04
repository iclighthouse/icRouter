import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import IC "mo:icl/IC";
import Cycles "mo:base/ExperimentalCycles";

module{
    public func transform(raw : IC.TransformArgs) : IC.HttpResponsePayload {
        let transformed : IC.HttpResponsePayload = {
            status = raw.response.status;
            body = raw.response.body;
            headers = [
                { name = "Content-Security-Policy"; value = "default-src 'self'"; },
                { name = "Referrer-Policy"; value = "strict-origin" },
                { name = "Permissions-Policy"; value = "geolocation=(self)" },
                { name = "Strict-Transport-Security"; value = "max-age=63072000"; },
                { name = "X-Frame-Options"; value = "DENY" },
                { name = "X-Content-Type-Options"; value = "nosniff" },
            ];
        };
        return transformed;
    };
    public func getHost(_rpcUrl: Text): Text{
        // Example: https://eth-goerli.g.alchemy.com/v2/xxxxxxx
        let step1 = Text.trimStart(_rpcUrl, #text("https://"));
        let step2: [Text] = Iter.toArray(Text.split(step1, #char('/')));
        return step2[0];
    };
    public func call(_rpcUrl: Text, _input: Text, _responseSize: Nat64, _addCycles: Nat, _transform: ?IC.TransformRawResponseFunction) : async* (status: Nat, body: Blob, json: Text){ // (Nat, Blob, Text, Nat)
        let host : Text = getHost(_rpcUrl);
        let request_headers = [
            { name = "Host"; value = host # ":443" },
            { name = "Content-Type"; value = "application/json" },
            { name = "User-Agent"; value = "IC/RPC-Caller" },
            // { name = "User-Agent"; value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36" }, // Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
            // { name = "User-Agent"; value = "PostmanRuntime/7.29.2" }
            // { name = "apikey"; value = key },
        ];
        let request : IC.HttpRequestArgs = { 
            url = _rpcUrl; 
            max_response_bytes = ?_responseSize;  
            headers = request_headers;
            body = ?Blob.toArray(Text.encodeUtf8(_input));
            method = #post;
            transform = _transform;
        };
        Cycles.add<system>(_addCycles);
        let ic : IC.Self = actor ("aaaaa-aa");
        let response = await ic.http_request(request);
        let resBody: Blob = Blob.fromArray(response.body);
        let resJson: Text = Option.get(Text.decodeUtf8(resBody), "");
        return (response.status, resBody, resJson);
    };
};