import Testing
@testable import NyxCore

@Test func plainCurlIsDetected() {
    #expect(CurlDetection.isCurl("curl https://x"))
}

@Test func aVariableAssignmentAndSudoAheadOfCurlIsStillDetected() {
    #expect(CurlDetection.isCurl("API=1 sudo curl https://x"))
}

@Test func timeAheadOfCurlIsStillDetected() {
    #expect(CurlDetection.isCurl("time curl https://x"))
}

@Test func curlPipedIntoAnotherProgramIsStillDetected() {
    #expect(CurlDetection.isCurl("curl https://x | jq ."))
}

@Test func curlReadingSomeoneElsesOutputIsNotDetected() {
    // `curl` here is the second stage of the pipeline -- it consumes `cat b`'s output as its
    // body, it does not make the request the line is "about" for Nyx's purposes.
    #expect(!CurlDetection.isCurl("cat b | curl -d @- https://x"))
}

@Test func aLookalikeCommandNameIsNotDetected() {
    #expect(!CurlDetection.isCurl("curlx https://x"))
}

@Test func theWordCurlAsAnArgumentIsNotDetected() {
    #expect(!CurlDetection.isCurl("echo curl"))
}

@Test func anEmptyLineIsNotDetected() {
    #expect(!CurlDetection.isCurl(""))
}
