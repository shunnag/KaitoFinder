import Foundation
import GyoshukuKit

/// 設定の説明とツールチップは同じ訳を使う。
enum CompressionOptionHelp {
    static func zip(_ method: ArchivePreferences.ZipMethod, bundle: Bundle = .main) -> String {
        switch method {
        case .deflate: String(localized: "標準の方式です。macOSのアーカイブユーティリティやWindowsなど、ほぼすべての環境で開けます。迷ったらこれがおすすめです。", bundle: bundle)
        case .stored: String(localized: "圧縮せずに格納します。最も速く、どこでも開けます。写真や動画など、圧縮済みのファイルをまとめるときに向いています。", bundle: bundle)
        case .bzip2: String(localized: "Deflateより圧縮率が高めですが、遅い方式です。macOSのアーカイブユーティリティやunzipでは開けません。", bundle: bundle)
        case .lzma: String(localized: "圧縮率の高い方式です。大きなファイルは分割せずに1つの流れで圧縮するため、並列化されません。macOSのアーカイブユーティリティやunzipでは開けません。", bundle: bundle)
        case .xz: String(localized: "LZMA2による圧縮率の高い方式です。大きなファイルも分割して並列に圧縮します。macOSのアーカイブユーティリティやunzipでは開けません。", bundle: bundle)
        case .zstd: String(localized: "高速で、圧縮率も比較的高い新しい方式です。macOSのアーカイブユーティリティやunzipでは開けません。", bundle: bundle)
        case .ppmd: String(localized: "テキストの圧縮に強い方式です。ファイルを分割しないため、大きなファイルは並列化されません。macOSのアーカイブユーティリティやunzipでは開けません。", bundle: bundle)
        }
    }

    static func sevenZip(_ method: ArchiveSavePanelController.Method, bundle: Bundle = .main) -> String {
        switch method {
        case .lzma2: String(localized: "7zの標準の方式です。圧縮率が高く、大きなファイルも分割して並列に圧縮します。おすすめです。", bundle: bundle)
        case .lzma: String(localized: "LZMA2の前身の方式です。ブロックを分割しないため、大きなファイルは並列化されにくくなります。", bundle: bundle)
        case .deflate: String(localized: "高速ですが、圧縮率はLZMA2より低めです。", bundle: bundle)
        case .bzip2: String(localized: "bzip2による方式です。大きなデータも分割して並列に圧縮します。", bundle: bundle)
        case .ppmd: String(localized: "テキストの圧縮に強い方式です。ブロックを分割しないため、大きなファイルは並列化されません。", bundle: bundle)
        default: ""
        }
    }

    static func filter(_ filter: ArchivePreferences.SevenZipFilter, bundle: Bundle = .main) -> String {
        switch filter {
        case .none: String(localized: "フィルタを使いません。", bundle: bundle)
        case .auto: String(localized: "各ファイルの先頭を調べ、x86・x86_64やarm64の実行ファイルにだけ、それぞれに適したフィルタを使います。", bundle: bundle)
        case .bcjX86: String(localized: "x86・x86_64の実行ファイルの圧縮率を上げます。それ以外のファイルには効果がありません。", bundle: bundle)
        case .arm64: String(localized: "arm64の実行ファイルの圧縮率を上げます。それ以外のファイルには効果がありません。", bundle: bundle)
        case .delta: String(localized: "4バイト単位の数値が並ぶデータ（32ビットの音声サンプルなど）の圧縮率を上げます。", bundle: bundle)
        }
    }

    static func tar(_ format: GyoshukuKit.ArchiveFormat, bundle: Bundle = .main) -> String {
        switch format {
        case .tarGzip: String(localized: "最も広く使われる方式です。どの環境でも開け、速さと圧縮率のバランスが良いのでおすすめです。", bundle: bundle)
        case .tarBzip2: String(localized: "gzipより圧縮率が高めですが、遅い方式です。レベルはブロックの大きさ（100〜900 KB）を決めます。", bundle: bundle)
        case .tarXZ: String(localized: "圧縮率の高い方式です。大きなデータも分割して並列に圧縮します。デフォルトのレベルでは、圧縮に1スレッドあたり約135 MBのメモリを使います。レベルを上げるとさらに増えます。", bundle: bundle)
        case .tarZstd: String(localized: "高速で、圧縮率も比較的高い新しい方式です。編集するたびにアーカイブ全体を書き直します。", bundle: bundle)
        case .tarLzip: String(localized: "LZMAによる圧縮率の高い方式で、各部分にCRC32のチェックサムを持ちます。編集するたびにアーカイブ全体を書き直します。", bundle: bundle)
        case .tarLZMA: String(localized: "古いLZMA形式です。並列化されません。新しく作るならxzかlzipがおすすめです。", bundle: bundle)
        default: ""
        }
    }

    static func lha(_ method: ArchiveSavePanelController.Method, bundle: Bundle = .main) -> String {
        switch method {
        case .lh5: String(localized: "最も広く使われているLHAの方式です（辞書8 KB）。おすすめです。", bundle: bundle)
        case .lh6: String(localized: "辞書32 KBの方式です。lh5より圧縮率が上がることがあります。", bundle: bundle)
        case .lh7: String(localized: "辞書64 KBの方式です。3つのうちで圧縮率が最も高くなりやすい方式です。", bundle: bundle)
        default: ""
        }
    }

    static func level(bundle: Bundle = .main) -> String {
        String(localized: "数字が大きいほど圧縮率が上がり、時間がかかります。", bundle: bundle)
    }
    static func solid(bundle: Bundle = .main) -> String {
        String(localized: "複数のファイルをまとめて圧縮し、似たファイルが多いと圧縮率が上がります。ソリッドブロック内の項目を削除すると、そのブロックを再圧縮します。また、項目のサムネールや自動プレビューは表示されません。", bundle: bundle)
    }
    static func skipsCompressedTypes(bundle: Bundle = .main) -> String {
        String(localized: "zip・jpg・mp4など、すでに圧縮されているファイルを再圧縮せずに格納し、時間を節約します。", bundle: bundle)
    }
    static func threads(bundle: Bundle = .main) -> String {
        String(localized: "圧縮に使うスレッド数です。自動では、Macのコア数とメモリから決めます。展開には影響しません。", bundle: bundle)
    }
    static func power(bundle: Bundle = .main) -> String {
        String(localized: "自動の並列数を、低電力モードや高温時に減らすかどうかを決めます。圧縮と展開の両方に使います。", bundle: bundle)
    }
    static func speed(bundle: Bundle = .main) -> String {
        String(localized: "ZIPのXZ・Zstandard、7zのLZMA2、単体の.xz・.lzで、データを細かく分けて並列に圧縮します。サイズはわずかに大きくなります。", bundle: bundle)
    }
}
