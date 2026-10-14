from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
class YandexSearchTests(unittest.TestCase):
    def test_search_uses_server_order_and_reports_failure(self):
        s=(ROOT/'Sonivo/yandexcatalogfix.swift').read_text().split('func searchCatalog',1)[1].split('func getArtistFixed',1)[0]
        for token in ['try await sessionData','YandexSearchContract.validate','try Task.checkCancellation()','generation == accountGeneration','result.misspellCorrected','result.best?.track','hasNext','kind: kind,page: page,noCorrect: noCorrect']:
            self.assertIn(token,s)
        for unwanted in ['.sort', '.sorted','ArtistExact','monthRank','try? await sessionData']:
            self.assertNotIn(unwanted,s)
        legacy=(ROOT/'Sonivo/yandexmusicservice.swift').read_text().split('func search(query:',1)[1].split('// MARK:',1)[0]
        self.assertIn('kind: .track,page: page',legacy)
    def test_search_is_immediate_and_stale_requests_are_cancelled(self):
        root=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        field=(ROOT/'Sonivo/SonivoSearchField.swift').read_text()
        self.assertIn('.focused($focused)',field);self.assertIn('.task(id: isActive)',field)
        self.assertIn('await Task.yield()',field);self.assertNotIn('Task.sleep',field)
        for view in ['SearchCatalogView','SonivoLocalSearchView','SpotifyCatalogSearchView']:
            self.assertIn(view+'(isActive: tab == .search)',root)
        ui=(ROOT/'Sonivo/searchviews.swift').read_text()
        self.assertNotIn('.searchable',ui)
        self.assertNotIn("results.artists.prefix(12)",ui)
        self.assertNotIn("results.albums.prefix(12)",ui)
        for text in ['requestID == id','searchTask?.cancel()','async let hints','kind: selectedKind,page: nextPage,noCorrect: exact','Искать исходный запрос','Показать ещё','Поиск недоступен','lastRequestWasMore=more']:
            self.assertIn(text,ui)
        self.assertLess(ui.index('results=found'),ui.index('let suggested=await hints'))
        body=ui.split('private func performSearch',1)[1]
        self.assertLess(body.index('try await ym.searchCatalog'),body.index('saveSearchQuery(query)'))
    @unittest.skipUnless(shutil.which('swiftc'),'Swift compiler required')
    def test_actual_request_and_response_contract(self):
        contract=(ROOT/'Sonivo/YandexSearchContract.swift').read_text()
        models=(ROOT/'Sonivo/yandexcatalogfix.swift').read_text().split('private struct YMCatalogArtistCover',1)[1].split('private struct YMCatalogArtistDetails',1)[0]
        models='private struct YMCatalogArtistCover'+models
        stub='''
nonisolated enum YandexMusicService {
    struct YMTrackItem: Decodable { let id: String; let title: String }
    struct YMAlbumItem: Decodable { let id: Int; let title: String? }
}
'''
        fixture=r'''
func check(_ x: Bool) { if !x { fatalError("search fixture") } }
for kind in YandexSearchKind.allCases {
    let url=try YandexSearchContract.url(base:"https://api.music.yandex.net",text:"  AC/DC  +  & музыка \n ",kind:kind,page:2,noCorrect:true)
    let q=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
    check(q.first(where:{$0.name == "text"})!.value == "AC/DC + & музыка")
    check(URLComponents(url:url,resolvingAgainstBaseURL:false)!.percentEncodedQuery!.contains("%2B"))
    check(q.first(where:{$0.name == "type"})!.value == kind.rawValue)
    check(q.first(where:{$0.name == "page"})!.value == "2")
    check(q.first(where:{$0.name == "nocorrect"})!.value == "true")
    check(q.first(where:{$0.name == "playlist-in-best"})!.value == "false")
}
check(YandexSearchContract.hasNext(total:21,perPage:20,page:0))
check(!YandexSearchContract.hasNext(total:21,perPage:20,page:1))
check(!YandexSearchContract.hasNext(total:0,perPage:0,page:0))
for status in [401,403,429,503] {
    let r=HTTPURLResponse(url:URL(string:"https://api.music.yandex.net/search")!,statusCode:status,httpVersion:nil,headerFields:nil)!
    do { try YandexSearchContract.validate(r,bytes:1); fatalError("HTTP failure accepted") } catch is YandexSearchError {}
}
let data=Data(#"{"result":{"misspellCorrected":true,"misspellResult":"Гражданская оборона","best":{"type":"track","result":{"id":"88","title":"Точное имя"}},"tracks":{"total":21,"perPage":20,"results":[{"id":"9","title":"Z first"},{"id":"2","title":"A second"}]},"artists":{"results":[{"id":42,"name":"Number"},{"id":"43","name":"String","cover":{"uri":"cover/%%"}}]}}}"#.utf8)
private let result=try JSONDecoder().decode(YMCatalogSearchResponse.self,from:data).result!
check(result.tracks!.results!.map(\.id) == ["9","2"])
check(result.best!.track!.id == "88")
check(result.artists!.results!.map(\.id) == ["42","43"])
check(result.misspellCorrected == true && result.misspellResult == "Гражданская оборона")
print("Search requests, server order, correction, best result, IDs, pagination and HTTP errors passed")
'''
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'main.swift').write_text(contract+stub+models+fixture)
            result=subprocess.run(['swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'test')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            subprocess.run([str(p/'test')],check=True)
