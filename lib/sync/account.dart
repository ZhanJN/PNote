/// 「账号」= 一个名字，代表你想和谁同步（1.51 / M22）。
///
/// 这不是登录账号，也没有密码：**同名设备互相同步**，仅此而已。
/// 为什么做得这么轻（用户 2026-11-24 的决定）：
///   - 这是纯局域网、无服务器的自用工具，引服务器/加密会让「两台设备
///     换个名字」都变复杂；
///   - 需求本身只是「把家里的设备和别人的设备分开」，名字就够。
///
/// 「公开同步」不是特殊模式，只是一个内置的账号名：选了它的设备彼此
/// 同名，于是互相全量同步 —— 相当于局域网里的临时共享账号。
/// 因为它会把任务和笔记都给同一个 Wi-Fi 下的陌生人，界面上要弹风险提示。
library;

/// 存在 meta 表里的键。本机偏好，不参与同步（各设备自己选）。
const String kAccountKey = 'account_name';

/// 上一次用的「非公开」账号名（1.52）。切到「公开同步」时不覆盖它，
/// 切回来时用它恢复 —— 避免用户发现自己的名字被「公开同步」顶掉。
const String kAccountPrivateKey = 'account_private_name';

/// 默认账号。升级后所有设备都用它，所以老用户的两台设备仍然互相同步。
const String kDefaultAccount = '我的 PNote';

/// 内置的「公开同步」账号名。
const String kPublicAccount = '公开同步';

/// 设置页里直接可点的预设；用户也可以自己打字。
const List<String> kAccountPresets = [kDefaultAccount, kPublicAccount];

/// 名字最长多少字。太长会把连接设备页挤爆，也没有实际意义。
const int kAccountMaxLength = 24;

/// 去掉首尾空白；空名退回默认账号。
String normalizeAccount(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kDefaultAccount;
  return trimmed.length <= kAccountMaxLength
      ? trimmed
      : trimmed.substring(0, kAccountMaxLength);
}

/// 是否选了「公开同步」这个内置账号（用来弹风险提示）。
bool isPublicAccount(String name) => name == kPublicAccount;

/// 打开账号对话框时输入框应预填的名字（1.52）。
///
/// 当前是「公开同步」时，预填上次用过的私有账号名，而不是「公开同步」，
/// 这样点「保存」就能切回去；否则预填当前名字。
String accountDraft(String current, String lastPrivate) =>
    isPublicAccount(current)
        ? normalizeAccount(lastPrivate)
        : normalizeAccount(current);

/// 拨号后发现对端账号和自己不一样时抛这个（不再合并，直接结束这一趟）。
///
/// 用独立异常而不是 PayloadException：上层要把它翻译成
/// 「账号不同」而不是「协议不兼容」，用户看到的提示完全不同。
class AccountMismatch implements Exception {
  const AccountMismatch(this.peerAccount);

  final String peerAccount;

  @override
  String toString() => '账号不同（对方「$peerAccount」）';
}
