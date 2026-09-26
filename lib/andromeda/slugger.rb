# frozen_string_literal: true

module Andromeda
  # Ruby port of npm `github-slugger` (MIT, https://github.com/Flet/github-slugger),
  # the algorithm Astro uses for heading anchor ids. Ported rather than reimplemented
  # from scratch because the exact punctuation-stripping regex is the entire
  # compatibility surface here: any deviation changes which headings get an
  # `-1` suffix, breaking anchors that Astro-authored content links to.
  #
  # `STRIP` below is that package's `regex.js`, mechanically translated from
  # JS's UTF-16 surrogate-pair escapes to single-codepoint `\u{...}` Ruby
  # escapes (Ruby strings are UTF-8, not UTF-16, so a JS `\uD83D[\uDE00-\uDE4F]`
  # pair becomes one `\u{1F600}-\u{1F64F}` range here). Verified against
  # github-slugger's own `test/fixtures.json` (78 cases: ASCII, punctuation,
  # camelCase, emoji, `__proto__`/`hasOwnProperty` key-injection guards,
  # repetition) with zero failures before landing.
  class Slugger
    # rubocop:disable Layout/LineLength
    STRIP = /[\u{0}-\u{1F}\u{21}-\u{2C}\u{2E}\u{2F}\u{3A}-\u{40}\u{5B}-\u{5E}\u{60}\u{7B}-\u{A9}\u{AB}-\u{B4}\u{B6}-\u{B9}\u{BB}-\u{BF}\u{D7}\u{F7}\u{2C2}-\u{2C5}\u{2D2}-\u{2DF}\u{2E5}-\u{2EB}\u{2ED}\u{2EF}-\u{2FF}\u{375}\u{378}\u{379}\u{37E}\u{380}-\u{385}\u{387}\u{38B}\u{38D}\u{3A2}\u{3F6}\u{482}\u{530}\u{557}\u{558}\u{55A}-\u{55F}\u{589}-\u{590}\u{5BE}\u{5C0}\u{5C3}\u{5C6}\u{5C8}-\u{5CF}\u{5EB}-\u{5EE}\u{5F3}-\u{60F}\u{61B}-\u{61F}\u{66A}-\u{66D}\u{6D4}\u{6DD}\u{6DE}\u{6E9}\u{6FD}\u{6FE}\u{700}-\u{70F}\u{74B}\u{74C}\u{7B2}-\u{7BF}\u{7F6}-\u{7F9}\u{7FB}\u{7FC}\u{7FE}\u{7FF}\u{82E}-\u{83F}\u{85C}-\u{85F}\u{86B}-\u{89F}\u{8B5}\u{8C8}-\u{8D2}\u{8E2}\u{964}\u{965}\u{970}\u{984}\u{98D}\u{98E}\u{991}\u{992}\u{9A9}\u{9B1}\u{9B3}-\u{9B5}\u{9BA}\u{9BB}\u{9C5}\u{9C6}\u{9C9}\u{9CA}\u{9CF}-\u{9D6}\u{9D8}-\u{9DB}\u{9DE}\u{9E4}\u{9E5}\u{9F2}-\u{9FB}\u{9FD}\u{9FF}\u{A00}\u{A04}\u{A0B}-\u{A0E}\u{A11}\u{A12}\u{A29}\u{A31}\u{A34}\u{A37}\u{A3A}\u{A3B}\u{A3D}\u{A43}-\u{A46}\u{A49}\u{A4A}\u{A4E}-\u{A50}\u{A52}-\u{A58}\u{A5D}\u{A5F}-\u{A65}\u{A76}-\u{A80}\u{A84}\u{A8E}\u{A92}\u{AA9}\u{AB1}\u{AB4}\u{ABA}\u{ABB}\u{AC6}\u{ACA}\u{ACE}\u{ACF}\u{AD1}-\u{ADF}\u{AE4}\u{AE5}\u{AF0}-\u{AF8}\u{B00}\u{B04}\u{B0D}\u{B0E}\u{B11}\u{B12}\u{B29}\u{B31}\u{B34}\u{B3A}\u{B3B}\u{B45}\u{B46}\u{B49}\u{B4A}\u{B4E}-\u{B54}\u{B58}-\u{B5B}\u{B5E}\u{B64}\u{B65}\u{B70}\u{B72}-\u{B81}\u{B84}\u{B8B}-\u{B8D}\u{B91}\u{B96}-\u{B98}\u{B9B}\u{B9D}\u{BA0}-\u{BA2}\u{BA5}-\u{BA7}\u{BAB}-\u{BAD}\u{BBA}-\u{BBD}\u{BC3}-\u{BC5}\u{BC9}\u{BCE}\u{BCF}\u{BD1}-\u{BD6}\u{BD8}-\u{BE5}\u{BF0}-\u{BFF}\u{C0D}\u{C11}\u{C29}\u{C3A}-\u{C3C}\u{C45}\u{C49}\u{C4E}-\u{C54}\u{C57}\u{C5B}-\u{C5F}\u{C64}\u{C65}\u{C70}-\u{C7F}\u{C84}\u{C8D}\u{C91}\u{CA9}\u{CB4}\u{CBA}\u{CBB}\u{CC5}\u{CC9}\u{CCE}-\u{CD4}\u{CD7}-\u{CDD}\u{CDF}\u{CE4}\u{CE5}\u{CF0}\u{CF3}-\u{CFF}\u{D0D}\u{D11}\u{D45}\u{D49}\u{D4F}-\u{D53}\u{D58}-\u{D5E}\u{D64}\u{D65}\u{D70}-\u{D79}\u{D80}\u{D84}\u{D97}-\u{D99}\u{DB2}\u{DBC}\u{DBE}\u{DBF}\u{DC7}-\u{DC9}\u{DCB}-\u{DCE}\u{DD5}\u{DD7}\u{DE0}-\u{DE5}\u{DF0}\u{DF1}\u{DF4}-\u{E00}\u{E3B}-\u{E3F}\u{E4F}\u{E5A}-\u{E80}\u{E83}\u{E85}\u{E8B}\u{EA4}\u{EA6}\u{EBE}\u{EBF}\u{EC5}\u{EC7}\u{ECE}\u{ECF}\u{EDA}\u{EDB}\u{EE0}-\u{EFF}\u{F01}-\u{F17}\u{F1A}-\u{F1F}\u{F2A}-\u{F34}\u{F36}\u{F38}\u{F3A}-\u{F3D}\u{F48}\u{F6D}-\u{F70}\u{F85}\u{F98}\u{FBD}-\u{FC5}\u{FC7}-\u{FFF}\u{104A}-\u{104F}\u{109E}\u{109F}\u{10C6}\u{10C8}-\u{10CC}\u{10CE}\u{10CF}\u{10FB}\u{1249}\u{124E}\u{124F}\u{1257}\u{1259}\u{125E}\u{125F}\u{1289}\u{128E}\u{128F}\u{12B1}\u{12B6}\u{12B7}\u{12BF}\u{12C1}\u{12C6}\u{12C7}\u{12D7}\u{1311}\u{1316}\u{1317}\u{135B}\u{135C}\u{1360}-\u{137F}\u{1390}-\u{139F}\u{13F6}\u{13F7}\u{13FE}-\u{1400}\u{166D}\u{166E}\u{1680}\u{169B}-\u{169F}\u{16EB}-\u{16ED}\u{16F9}-\u{16FF}\u{170D}\u{1715}-\u{171F}\u{1735}-\u{173F}\u{1754}-\u{175F}\u{176D}\u{1771}\u{1774}-\u{177F}\u{17D4}-\u{17D6}\u{17D8}-\u{17DB}\u{17DE}\u{17DF}\u{17EA}-\u{180A}\u{180E}\u{180F}\u{181A}-\u{181F}\u{1879}-\u{187F}\u{18AB}-\u{18AF}\u{18F6}-\u{18FF}\u{191F}\u{192C}-\u{192F}\u{193C}-\u{1945}\u{196E}\u{196F}\u{1975}-\u{197F}\u{19AC}-\u{19AF}\u{19CA}-\u{19CF}\u{19DA}-\u{19FF}\u{1A1C}-\u{1A1F}\u{1A5F}\u{1A7D}\u{1A7E}\u{1A8A}-\u{1A8F}\u{1A9A}-\u{1AA6}\u{1AA8}-\u{1AAF}\u{1AC1}-\u{1AFF}\u{1B4C}-\u{1B4F}\u{1B5A}-\u{1B6A}\u{1B74}-\u{1B7F}\u{1BF4}-\u{1BFF}\u{1C38}-\u{1C3F}\u{1C4A}-\u{1C4C}\u{1C7E}\u{1C7F}\u{1C89}-\u{1C8F}\u{1CBB}\u{1CBC}\u{1CC0}-\u{1CCF}\u{1CD3}\u{1CFB}-\u{1CFF}\u{1DFA}\u{1F16}\u{1F17}\u{1F1E}\u{1F1F}\u{1F46}\u{1F47}\u{1F4E}\u{1F4F}\u{1F58}\u{1F5A}\u{1F5C}\u{1F5E}\u{1F7E}\u{1F7F}\u{1FB5}\u{1FBD}\u{1FBF}-\u{1FC1}\u{1FC5}\u{1FCD}-\u{1FCF}\u{1FD4}\u{1FD5}\u{1FDC}-\u{1FDF}\u{1FED}-\u{1FF1}\u{1FF5}\u{1FFD}-\u{203E}\u{2041}-\u{2053}\u{2055}-\u{2070}\u{2072}-\u{207E}\u{2080}-\u{208F}\u{209D}-\u{20CF}\u{20F1}-\u{2101}\u{2103}-\u{2106}\u{2108}\u{2109}\u{2114}\u{2116}-\u{2118}\u{211E}-\u{2123}\u{2125}\u{2127}\u{2129}\u{212E}\u{213A}\u{213B}\u{2140}-\u{2144}\u{214A}-\u{214D}\u{214F}-\u{215F}\u{2189}-\u{24B5}\u{24EA}-\u{2BFF}\u{2C2F}\u{2C5F}\u{2CE5}-\u{2CEA}\u{2CF4}-\u{2CFF}\u{2D26}\u{2D28}-\u{2D2C}\u{2D2E}\u{2D2F}\u{2D68}-\u{2D6E}\u{2D70}-\u{2D7E}\u{2D97}-\u{2D9F}\u{2DA7}\u{2DAF}\u{2DB7}\u{2DBF}\u{2DC7}\u{2DCF}\u{2DD7}\u{2DDF}\u{2E00}-\u{2E2E}\u{2E30}-\u{3004}\u{3008}-\u{3020}\u{3030}\u{3036}\u{3037}\u{303D}-\u{3040}\u{3097}\u{3098}\u{309B}\u{309C}\u{30A0}\u{30FB}\u{3100}-\u{3104}\u{3130}\u{318F}-\u{319F}\u{31C0}-\u{31EF}\u{3200}-\u{33FF}\u{4DC0}-\u{4DFF}\u{9FFD}-\u{9FFF}\u{A48D}-\u{A4CF}\u{A4FE}\u{A4FF}\u{A60D}-\u{A60F}\u{A62C}-\u{A63F}\u{A673}\u{A67E}\u{A6F2}-\u{A716}\u{A720}\u{A721}\u{A789}\u{A78A}\u{A7C0}\u{A7C1}\u{A7CB}-\u{A7F4}\u{A828}-\u{A82B}\u{A82D}-\u{A83F}\u{A874}-\u{A87F}\u{A8C6}-\u{A8CF}\u{A8DA}-\u{A8DF}\u{A8F8}-\u{A8FA}\u{A8FC}\u{A92E}\u{A92F}\u{A954}-\u{A95F}\u{A97D}-\u{A97F}\u{A9C1}-\u{A9CE}\u{A9DA}-\u{A9DF}\u{A9FF}\u{AA37}-\u{AA3F}\u{AA4E}\u{AA4F}\u{AA5A}-\u{AA5F}\u{AA77}-\u{AA79}\u{AAC3}-\u{AADA}\u{AADE}\u{AADF}\u{AAF0}\u{AAF1}\u{AAF7}-\u{AB00}\u{AB07}\u{AB08}\u{AB0F}\u{AB10}\u{AB17}-\u{AB1F}\u{AB27}\u{AB2F}\u{AB5B}\u{AB6A}-\u{AB6F}\u{ABEB}\u{ABEE}\u{ABEF}\u{ABFA}-\u{ABFF}\u{D7A4}-\u{D7AF}\u{D7C7}-\u{D7CA}\u{D7FC}-\u{D7FF}\u{E000}-\u{F8FF}\u{FA6E}\u{FA6F}\u{FADA}-\u{FAFF}\u{FB07}-\u{FB12}\u{FB18}-\u{FB1C}\u{FB29}\u{FB37}\u{FB3D}\u{FB3F}\u{FB42}\u{FB45}\u{FBB2}-\u{FBD2}\u{FD3E}-\u{FD4F}\u{FD90}\u{FD91}\u{FDC8}-\u{FDEF}\u{FDFC}-\u{FDFF}\u{FE10}-\u{FE1F}\u{FE30}-\u{FE32}\u{FE35}-\u{FE4C}\u{FE50}-\u{FE6F}\u{FE75}\u{FEFD}-\u{FF0F}\u{FF1A}-\u{FF20}\u{FF3B}-\u{FF3E}\u{FF40}\u{FF5B}-\u{FF65}\u{FFBF}-\u{FFC1}\u{FFC8}\u{FFC9}\u{FFD0}\u{FFD1}\u{FFD8}\u{FFD9}\u{FFDD}-\u{FFFF}\u{1000C}\u{10027}\u{1003B}\u{1003E}\u{1004E}\u{1004F}\u{1005E}-\u{1007F}\u{100FB}-\u{1013F}\u{10175}-\u{101FC}\u{101FE}-\u{1027F}\u{1029D}-\u{1029F}\u{102D1}-\u{102DF}\u{102E1}-\u{102FF}\u{10320}-\u{1032C}\u{1034B}-\u{1034F}\u{1037B}-\u{1037F}\u{1039E}\u{1039F}\u{103C4}-\u{103C7}\u{103D0}\u{103D6}-\u{103FF}\u{1049E}\u{1049F}\u{104AA}-\u{104AF}\u{104D4}-\u{104D7}\u{104FC}-\u{104FF}\u{10528}-\u{1052F}\u{10564}-\u{105FF}\u{10737}-\u{1073F}\u{10756}-\u{1075F}\u{10768}-\u{107FF}\u{10806}\u{10807}\u{10809}\u{10836}\u{10839}-\u{1083B}\u{1083D}\u{1083E}\u{10856}-\u{1085F}\u{10877}-\u{1087F}\u{1089F}-\u{108DF}\u{108F3}\u{108F6}-\u{108FF}\u{10916}-\u{1091F}\u{1093A}-\u{1097F}\u{109B8}-\u{109BD}\u{109C0}-\u{109FF}\u{10A04}\u{10A07}-\u{10A0B}\u{10A14}\u{10A18}\u{10A36}\u{10A37}\u{10A3B}-\u{10A3E}\u{10A40}-\u{10A5F}\u{10A7D}-\u{10A7F}\u{10A9D}-\u{10ABF}\u{10AC8}\u{10AE7}-\u{10AFF}\u{10B36}-\u{10B3F}\u{10B56}-\u{10B5F}\u{10B73}-\u{10B7F}\u{10B92}-\u{10BFF}\u{10C49}-\u{10C7F}\u{10CB3}-\u{10CBF}\u{10CF3}-\u{10CFF}\u{10D28}-\u{10D2F}\u{10D3A}-\u{10E7F}\u{10EAA}\u{10EAD}-\u{10EAF}\u{10EB2}-\u{10EFF}\u{10F1D}-\u{10F26}\u{10F28}-\u{10F2F}\u{10F51}-\u{10FAF}\u{10FC5}-\u{10FDF}\u{10FF7}-\u{10FFF}\u{11047}-\u{11065}\u{11070}-\u{1107E}\u{110BB}-\u{110CF}\u{110E9}-\u{110EF}\u{110FA}-\u{110FF}\u{11135}\u{11140}-\u{11143}\u{11148}-\u{1114F}\u{11174}\u{11175}\u{11177}-\u{1117F}\u{111C5}-\u{111C8}\u{111CD}\u{111DB}\u{111DD}-\u{111FF}\u{11212}\u{11238}-\u{1123D}\u{1123F}-\u{1127F}\u{11287}\u{11289}\u{1128E}\u{1129E}\u{112A9}-\u{112AF}\u{112EB}-\u{112EF}\u{112FA}-\u{112FF}\u{11304}\u{1130D}\u{1130E}\u{11311}\u{11312}\u{11329}\u{11331}\u{11334}\u{1133A}\u{11345}\u{11346}\u{11349}\u{1134A}\u{1134E}\u{1134F}\u{11351}-\u{11356}\u{11358}-\u{1135C}\u{11364}\u{11365}\u{1136D}-\u{1136F}\u{11375}-\u{113FF}\u{1144B}-\u{1144F}\u{1145A}-\u{1145D}\u{11462}-\u{1147F}\u{114C6}\u{114C8}-\u{114CF}\u{114DA}-\u{1157F}\u{115B6}\u{115B7}\u{115C1}-\u{115D7}\u{115DE}-\u{115FF}\u{11641}-\u{11643}\u{11645}-\u{1164F}\u{1165A}-\u{1167F}\u{116B9}-\u{116BF}\u{116CA}-\u{116FF}\u{1171B}\u{1171C}\u{1172C}-\u{1172F}\u{1173A}-\u{117FF}\u{1183B}-\u{1189F}\u{118EA}-\u{118FE}\u{11907}\u{11908}\u{1190A}\u{1190B}\u{11914}\u{11917}\u{11936}\u{11939}\u{1193A}\u{11944}-\u{1194F}\u{1195A}-\u{1199F}\u{119A8}\u{119A9}\u{119D8}\u{119D9}\u{119E2}\u{119E5}-\u{119FF}\u{11A3F}-\u{11A46}\u{11A48}-\u{11A4F}\u{11A9A}-\u{11A9C}\u{11A9E}-\u{11ABF}\u{11AF9}-\u{11BFF}\u{11C09}\u{11C37}\u{11C41}-\u{11C4F}\u{11C5A}-\u{11C71}\u{11C90}\u{11C91}\u{11CA8}\u{11CB7}-\u{11CFF}\u{11D07}\u{11D0A}\u{11D37}-\u{11D39}\u{11D3B}\u{11D3E}\u{11D48}-\u{11D4F}\u{11D5A}-\u{11D5F}\u{11D66}\u{11D69}\u{11D8F}\u{11D92}\u{11D99}-\u{11D9F}\u{11DAA}-\u{11EDF}\u{11EF7}-\u{11FAF}\u{11FB1}-\u{11FFF}\u{1239A}-\u{123FF}\u{1246F}-\u{1247F}\u{12544}-\u{127FF}\u{12800}-\u{12BFF}\u{12C00}-\u{12FFF}\u{13800}-\u{143FF}\u{14800}-\u{167FF}\u{19000}-\u{1AFFF}\u{1B400}-\u{1B7FF}\u{1B800}-\u{1BBFF}\u{1C000}-\u{1CFFF}\u{1DC00}-\u{1DFFF}\u{1E400}-\u{1E7FF}\u{1F400}-\u{1F7FF}\u{1FC00}-\u{1FFFF}\u{2EC00}-\u{2F7FF}\u{2FC00}-\u{2FFFF}\u{31400}-\u{DFFFF}\u{E0400}-\u{10FFFF}\u{1342F}-\u{137FF}\u{14647}-\u{147FF}\u{16A39}-\u{16A3F}\u{16A5F}\u{16A6A}-\u{16ACF}\u{16AEE}\u{16AEF}\u{16AF5}-\u{16AFF}\u{16B37}-\u{16B3F}\u{16B44}-\u{16B4F}\u{16B5A}-\u{16B62}\u{16B78}-\u{16B7C}\u{16B90}-\u{16BFF}\u{16C00}-\u{16E3F}\u{16E80}-\u{16EFF}\u{16F4B}-\u{16F4E}\u{16F88}-\u{16F8E}\u{16FA0}-\u{16FDF}\u{16FE2}\u{16FE5}-\u{16FEF}\u{16FF2}-\u{16FFF}\u{187F8}-\u{187FF}\u{18CD6}-\u{18CFF}\u{18D09}-\u{18FFF}\u{1B11F}-\u{1B14F}\u{1B153}-\u{1B163}\u{1B168}-\u{1B16F}\u{1B2FC}-\u{1B3FF}\u{1BC6B}-\u{1BC6F}\u{1BC7D}-\u{1BC7F}\u{1BC89}-\u{1BC8F}\u{1BC9A}-\u{1BC9C}\u{1BC9F}-\u{1BFFF}\u{1D000}-\u{1D164}\u{1D16A}-\u{1D16C}\u{1D173}-\u{1D17A}\u{1D183}\u{1D184}\u{1D18C}-\u{1D1A9}\u{1D1AE}-\u{1D241}\u{1D245}-\u{1D3FF}\u{1D455}\u{1D49D}\u{1D4A0}\u{1D4A1}\u{1D4A3}\u{1D4A4}\u{1D4A7}\u{1D4A8}\u{1D4AD}\u{1D4BA}\u{1D4BC}\u{1D4C4}\u{1D506}\u{1D50B}\u{1D50C}\u{1D515}\u{1D51D}\u{1D53A}\u{1D53F}\u{1D545}\u{1D547}-\u{1D549}\u{1D551}\u{1D6A6}\u{1D6A7}\u{1D6C1}\u{1D6DB}\u{1D6FB}\u{1D715}\u{1D735}\u{1D74F}\u{1D76F}\u{1D789}\u{1D7A9}\u{1D7C3}\u{1D7CC}\u{1D7CD}\u{1D800}-\u{1D9FF}\u{1DA37}-\u{1DA3A}\u{1DA6D}-\u{1DA74}\u{1DA76}-\u{1DA83}\u{1DA85}-\u{1DA9A}\u{1DAA0}\u{1DAB0}-\u{1DBFF}\u{1E007}\u{1E019}\u{1E01A}\u{1E022}\u{1E025}\u{1E02B}-\u{1E0FF}\u{1E12D}-\u{1E12F}\u{1E13E}\u{1E13F}\u{1E14A}-\u{1E14D}\u{1E14F}-\u{1E2BF}\u{1E2FA}-\u{1E3FF}\u{1E8C5}-\u{1E8CF}\u{1E8D7}-\u{1E8FF}\u{1E94C}-\u{1E94F}\u{1E95A}-\u{1EBFF}\u{1EC00}-\u{1EDFF}\u{1EE04}\u{1EE20}\u{1EE23}\u{1EE25}\u{1EE26}\u{1EE28}\u{1EE33}\u{1EE38}\u{1EE3A}\u{1EE3C}-\u{1EE41}\u{1EE43}-\u{1EE46}\u{1EE48}\u{1EE4A}\u{1EE4C}\u{1EE50}\u{1EE53}\u{1EE55}\u{1EE56}\u{1EE58}\u{1EE5A}\u{1EE5C}\u{1EE5E}\u{1EE60}\u{1EE63}\u{1EE65}\u{1EE66}\u{1EE6B}\u{1EE73}\u{1EE78}\u{1EE7D}\u{1EE7F}\u{1EE8A}\u{1EE9C}-\u{1EEA0}\u{1EEA4}\u{1EEAA}\u{1EEBC}-\u{1EFFF}\u{1F000}-\u{1F12F}\u{1F14A}-\u{1F14F}\u{1F16A}-\u{1F16F}\u{1F18A}-\u{1F3FF}\u{1F800}-\u{1FBEF}\u{1FBFA}-\u{1FBFF}\u{2A6DE}-\u{2A6FF}\u{2B735}-\u{2B73F}\u{2B81E}\u{2B81F}\u{2CEA2}-\u{2CEAF}\u{2EBE1}-\u{2EBFF}\u{2FA1E}-\u{2FBFF}\u{3134B}-\u{313FF}\u{E0000}-\u{E00FF}\u{E01F0}-\u{E03FF}]/.freeze
    # rubocop:enable Layout/LineLength

    def initialize
      reset
    end

    # Returns a slug unique within this instance's lifetime: a repeat of the
    # same heading text gets `-1`, `-2`, ... appended (matching remark's
    # rehype-collect-headings, which keeps one Slugger per document).
    #
    # @param text [String] heading text (already flattened to plain text --
    #   see Renderer::Headings for how child text nodes are joined).
    # @return [String]
    def slug(text)
      original = self.class.slugify(text)
      candidate = original

      # A `while`, not an `if`: the candidate can itself collide with an
      # earlier *explicit* occurrence (e.g. one heading literally titled
      # "Foo 1" followed by two headings titled "Foo"), so bumping once is
      # not always enough. This mirrors upstream's `BananaSlug#slug` loop.
      while @occurrences.key?(candidate)
        @occurrences[original] += 1
        candidate = "#{original}-#{@occurrences[original]}"
      end

      @occurrences[candidate] = 0
      candidate
    end

    # Forgets all previously generated slugs (upstream's `BananaSlug#reset`).
    def reset
      @occurrences = {}
    end

    # Stateless slugify, matching upstream's exported `slug()` function:
    # repeated calls with the same input return the same value (no `-1`
    # suffixing). Kept public because callers occasionally want to check
    # what an id *would* be without touching an instance's dedup state.
    #
    # @param text [String, nil]
    # @return [String]
    def self.slugify(text)
      return "" unless text.is_a?(String)

      text.downcase.gsub(STRIP, "").gsub(" ", "-")
    end
  end
end
