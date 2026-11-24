import 'package:flutter_test/flutter_test.dart';
import 'package:pnote/sync/account.dart';

/// 1.51 账号名的最小规则：去空白、空名回默认、超长截断、公开同步是预设之一。
void main() {
  test('去掉首尾空白', () {
    expect(normalizeAccount('  学习小组  '), '学习小组');
  });

  test('空名退回默认账号', () {
    expect(normalizeAccount(''), kDefaultAccount);
    expect(normalizeAccount('   '), kDefaultAccount);
  });

  test('超长名字截到 24 个字', () {
    final long = '一' * 40;
    final name = normalizeAccount(long);
    expect(name.length, kAccountMaxLength);
    expect(name, '一' * kAccountMaxLength);
  });

  test('预设里有默认账号和公开同步，且公开同步可识别', () {
    expect(kAccountPresets, contains(kDefaultAccount));
    expect(kAccountPresets, contains(kPublicAccount));
    expect(isPublicAccount(kPublicAccount), isTrue);
    expect(isPublicAccount(kDefaultAccount), isFalse);
  });

  test('AccountMismatch 的提示会带上对方账号名', () {
    expect(const AccountMismatch('公开同步').toString(), '账号不同（对方「公开同步」）');
  });

  test('公开同步时预填上次的私有账号名（1.52）', () {
    expect(accountDraft(kPublicAccount, '学习小组'), '学习小组');
    expect(accountDraft('学习小组', kPublicAccount), '学习小组');
    expect(accountDraft(kPublicAccount, ''), kDefaultAccount);
  });
}
