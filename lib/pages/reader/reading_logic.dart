part of 'comic_reading_page.dart';

/// 章末蓄力切章状态机。
///
/// 在翻页模式下滑到章节末尾后, 继续朝同一方向滑动会累积蓄力进度;
/// 进度充满时松手(或滚轮/键盘继续触发)切换到下一章, 中途停止则进度
/// 逐渐衰减归零。相比连续滚动模式的旧机制, 这里:
/// - 用带容差的 >= 比较代替浮点严格相等判断边界;
/// - 不依赖悬浮按钮状态(showFloatingButtonValue);
/// - 停止滑动约2秒后进度自动衰减, 而不是只在松手时清零;
/// - 同时响应触摸拖动/滚轮/键盘翻页。
class ChapterEndCharge {
  /// 已积累的蓄力进度(0~1)
  double _value = 0;

  /// 上次推进进度的时间
  DateTime _lastChargeTime = DateTime.now();

  Timer? _decayTimer;

  /// 进度变化回调(参数为0~1的进度值), 用于刷新UI
  void Function(double value)? onChanged;

  /// 是否正在蓄力(进度大于0)
  bool get isActive => _value > 0;

  double get value => _value.clamp(0.0, 1.0);

  static const double _fullValue = 1.0;

  /// 停止操作后开始衰减的延时
  static const Duration _decayDelay = Duration(milliseconds: 2000);

  /// 推进蓄力进度。[amount] 为本次操作折算的进度增量(正数)。
  /// 返回 true 表示已充满并应触发切章(由调用方执行跳转)。
  bool advance(double amount) {
    final now = DateTime.now();
    if (now.difference(_lastChargeTime) > _decayDelay && _value > 0) {
      // 距上次蓄力超过阈值, 视为重新开始
      _value = 0;
      onChanged?.call(0);
    }
    _lastChargeTime = now;
    _cancelDecay();
    _value = (_value + amount).clamp(0.0, _fullValue);
    if (_value >= _fullValue) {
      reset();
      return true;
    }
    onChanged?.call(_value);
    return false;
  }

  /// 启动衰减计时: 停止蓄力约2秒后进度回落到0
  void scheduleDecay() {
    if (_value <= 0) {
      return;
    }
    _cancelDecay();
    _decayTimer = Timer(_decayDelay, () {
      _value = 0;
      onChanged?.call(0);
    });
  }

  /// 立即重置(切页/换章/退出等场景)
  void reset() {
    _cancelDecay();
    if (_value != 0) {
      _value = 0;
      onChanged?.call(0);
    }
    _lastChargeTime = DateTime.now();
  }

  void _cancelDecay() {
    _decayTimer?.cancel();
    _decayTimer = null;
  }
}

/// 把一次翻页操作折算成蓄力进度增量: 约3次整屏操作蓄满。
double _chargeIncrementFor(double pageFraction) =>
    (pageFraction.abs() / 3).clamp(0.05, 1.0);

extension PageControllerExtension on PageController {
  void animatedJumpToPage(int page) {
    final current = this.page?.round() ?? 0;
    if ((current - page).abs() > 1) {
      jumpToPage(page > current ? page - 1 : page + 1);
    }
    animateToPage(page,
        duration: const Duration(milliseconds: 300), curve: Curves.ease);
  }

  void jumpByDeviceType(int page) {
    if (StateController.find<ComicReadingPageLogic>().mouseScroll) {
      jumpToPage(page);
    } else {
      animatedJumpToPage(page);
    }
  }
}

class ComicReadingPageLogic extends StateController {
  ///控制页面, 用于非从上至下(连续)阅读方式
  late PageController pageController;

  ///用于从上至下(连续)阅读方式, 跳转至指定项目
  var itemScrollController = ItemScrollController();

  ///用于从上至下(连续)阅读方式, 获取当前滚动到的元素的序号
  var itemScrollListener = ItemPositionsListener.create();

  ///用于从上至下(连续)阅读方式, 控制滚动
  var scrollController = ScrollController(keepScrollOffset: true);

  ///用于从上至下(连续)阅读方式, 获取放缩大小
  PhotoViewController get photoViewController =>
      photoViewControllers[index] ?? photoViewControllers[0]!;

  var photoViewControllers = <int, PhotoViewController>{};

  ListenVolumeController? listenVolume;

  ScrollManager? scrollManager;

  String? errorMessage;

  void clearPhotoViewControllers() {
    photoViewControllers.forEach((key, value) => value.dispose());
    photoViewControllers.clear();
  }

  bool noScroll = false;

  bool mouseScroll = false;

  double currentScale = 1.0;

  bool get isCtrlPressed => HardwareKeyboard.instance.isControlPressed;

  List<bool> requestedLoadingItems = [];

  bool haveUsedInitialPage = false;

  bool isOnChapterCommentsPage = false;

  /// 是否正处于章节末尾的空白页(仅翻页模式, 由 onPageChanged 维护)
  bool isOnEndBlankPage = false;

  /// 是否为连续滚动模式
  bool get isContinuousMode =>
      readingMethod == ReadingMethod.topToBottomContinuously;

  /// 是否启用"章末蓄力切下一章"(设置项105), 且当前确实存在下一章。
  /// 仅"从上至下(连续)"模式生效; 其余翻页模式保持原版行为(到章末直接切章)。
  bool get shouldChargeBeforeNextChapter =>
      isContinuousMode &&
      appdata.settings.length > 105 &&
      appdata.settings[105] == "1" &&
      data.hasEp &&
      order < (data.eps?.length ?? 1);

  /// 连续滚动模式下是否已滚动到本章末尾(带2px容差, 避免浮点严格相等)
  bool get isAtScrollEnd =>
      scrollController.hasClients &&
      scrollController.position.pixels >=
          scrollController.position.maxScrollExtent - 2.0;

  /// 章末蓄力状态机
  final chapterEndCharge = ChapterEndCharge();

  /// 双页模式下是否在第一页时显示单页
  bool get singlePageForFirstScreen => appdata.implicitData[1] == '1';

  var focusNode = FocusNode();

  static int _getIndex(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      return initPage % 2 == 1 ? initPage : initPage - 1;
    } else {
      return initPage;
    }
  }

  static int _getPage(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      return (initPage + 2) ~/ 2;
    } else {
      return initPage;
    }
  }

  ComicReadingPageLogic(
      this.order, this.data, int initialPage, this.updateHistory) {
    if (initialPage <= 0) {
      initialPage = 1;
    }
    pageController = _createPageController(_getPage(initialPage));
    _index = _getIndex(initialPage);
    order <= 0 ? order = 1 : order;
    itemScrollListener.itemPositions.addListener(() {
      var newIndex = itemScrollListener.itemPositions.value.first.index + 1;
      if (newIndex != index) {
        index = newIndex;
        update(["ToolBar"]);
      }
    });
  }

  PageController _createPageController(int initialPage) {
    final controller = PageController(initialPage: initialPage);
    controller.addListener(() {
      _syncIndexFromPageController();
    });
    return controller;
  }

  void _syncIndexFromPageController() {
    if (urls.isEmpty ||
        readingMethod == ReadingMethod.topToBottomContinuously ||
        !pageController.hasClients) {
      return;
    }
    final page = pageController.page?.round();
    if (page == null) {
      return;
    }
    int? newIndex;
    if (readingMethod.isTwoPage) {
      if (page <= 0) {
        return;
      }
      newIndex = singlePageForFirstScreen
          ? (page * 2 - 2).clamp(1, urls.length)
          : page * 2 - 1;
    } else {
      if (page <= 0 || page > urls.length) {
        return;
      }
      newIndex = page;
    }
    if (newIndex >= 1 && newIndex <= urls.length && newIndex != index) {
      index = newIndex;
    }
  }

  final void Function() updateHistory;

  ReadingData data;

  bool isLoading = true;

  ///旋转方向: null-跟随系统, false-竖向, true-横向
  bool? rotation;

  ///是否应该显示悬浮按钮, 为-1表示显示上一章, 为0表示不显示, 为1表示显示下一章
  int showFloatingButtonValue = 0;

  double fABValue = 0;

  void showFloatingButton(int value) {
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        fABValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0 && order != 1) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  late int _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  int get index => _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  set index(int value) {
    if (_index == value) {
      return;
    }
    _index = value;
    for (var element in _indexChangeCallbacks) {
      element(value);
    }
    updateHistory();
    update(["ToolBar"]);
  }

  final _indexChangeCallbacks = <void Function(int)>[];

  void Function(int)? continuationIndexCallback;

  void addIndexChangeCallback(void Function(int) callback) {
    _indexChangeCallbacks.add(callback);
  }

  void removeIndexChangeCallback(void Function(int) callback) {
    _indexChangeCallbacks.remove(callback);
  }

  ///当前的章节位置, 从1开始
  int order;

  ///工具栏是否打开
  bool tools = false;

  ///是否显示设置窗口
  bool showSettings = false;

  ///所有的图片链接
  var urls = <String>[];

  void reload() {
    index = 1;
    isOnChapterCommentsPage = false;
    isOnEndBlankPage = false;
    chapterEndCharge.reset();
    pageController = _createPageController(1);
    isLoading = true;
    requestedLoadingItems = [];
    update();
  }

  void change() {
    isLoading = !isLoading;
    update();
  }

  ReadingMethod get readingMethod =>
      ReadingMethod.values[int.parse(appdata.settings[9]) - 1];

  /// 当前是否处于章节末尾(翻页模式下最后一页或末尾评论页;
  /// 连续滚动模式下已滚动到底部)。
  /// 用于判断继续翻页/滚动时是否应进入蓄力而不是直接切章。
  bool get isAtChapterEnd =>
      shouldChargeBeforeNextChapter &&
      (isContinuousMode ? isAtScrollEnd : (isOnEndBlankPage || index >= urls.length));

  /// 章末蓄力: 推进进度, 充满后切换到下一章。
  /// [pageFraction] 为本次操作相当于整页的比例(如滚轮一格约0.4页)。
  /// 返回 true 表示本次调用触发了切章。
  bool chargeForNextChapter(double pageFraction) {
    if (!isAtChapterEnd) {
      return false;
    }
    final full = chapterEndCharge.advance(_chargeIncrementFor(pageFraction));
    if (full) {
      jumpToNextChapter();
      return true;
    }
    return false;
  }

  void jumpToNextPage() {
    // 章末蓄力: 最后一页继续翻页时先蓄力, 充满才切章
    if (isAtChapterEnd) {
      chargeForNextChapter(1);
      return;
    }
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index + 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels + 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() + 1);
    }
  }

  void jumpToLastPage() {
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index - 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels - 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() - 1);
    }
  }

  void jumpToPage(int i, [bool updateWidget = false]) {
    i = i.clamp(1, length);
    if (readingMethod == ReadingMethod.topToBottomContinuously) {
      itemScrollController.jumpTo(index: i - 1);
    } else if (!readingMethod.isTwoPage) {
      pageController.jumpToPage(i);
    } else {
      var page = singlePageForFirstScreen ? i ~/ 2 + 1 : (i + 1) ~/ 2;
      pageController.jumpToPage(page);
    }
    if (index != i) {
      index = i;
    }
    if (updateWidget) {
      update(["ToolBar"]);
    }
  }

  void jumpByDeviceType(int page) {
    Future.microtask(() {
      if (mouseScroll) {
        pageController.jumpToPage(page);
      } else {
        pageController.animatedJumpToPage(page);
      }
    });
  }

  void jumpToNextChapter() {
    var eps = data.eps;
    showFloatingButtonValue = 0;
    isOnEndBlankPage = false;
    chapterEndCharge.reset();
    if (!data.hasEp || order == eps?.length) {
      if (readingMethod != ReadingMethod.topToBottomContinuously) {
        if (readingMethod.index < 3) {
          jumpByDeviceType(urls.length);
        } else if (readingMethod == ReadingMethod.twoPage) {
          jumpByDeviceType((urls.length % 2 + urls.length) ~/ 2);
        }
      } else {
        jumpToPage(urls.length);
        index = urls.length;
        update(["ToolBar"]);
      }
      return;
    }
    order += 1;
    urls = [];
    isLoading = true;
    tools = false;
    index = 1;
    isOnChapterCommentsPage = false;
    pageController = _createPageController(1);
    requestedLoadingItems = [];
    clearPhotoViewControllers();
    update();
  }

  void jumpToChapter(int index) {
    order = index;
    urls = [];
    isLoading = true;
    tools = false;
    this.index = 1;
    isOnChapterCommentsPage = false;
    pageController = _createPageController(1);
    requestedLoadingItems = [];
    clearPhotoViewControllers();
    update();
  }

  void jumpToLastChapter() {
    showFloatingButtonValue = 0;
    if (order == 1 || !data.hasEp) {
      if (readingMethod != ReadingMethod.topToBottomContinuously) {
        jumpByDeviceType(1);
      } else {
        jumpToPage(1);
        index = 1;
        update(["ToolBar"]);
      }
      return;
    }

    order -= 1;
    urls = [];
    isLoading = true;
    tools = false;
    isOnChapterCommentsPage = false;
    pageController = _createPageController(1);
    index = 1;
    requestedLoadingItems = [];
    clearPhotoViewControllers();
    update();
  }

  ///当前章节的长度
  int get length => urls.length;

  /// 是否处于自动翻页状态
  bool runningAutoPageTurning = false;

  /// 自动翻页
  void autoPageTurning() async {
    if (index == urls.length - 1) {
      runningAutoPageTurning = false;
      update();
      return;
    }
    int sec = int.parse(appdata.settings[33]);
    for (int i = 0; i < sec * 10; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!runningAutoPageTurning) {
        return;
      }
    }
    jumpToNextPage();
    autoPageTurning();
  }

  void refresh_() {
    pageController = _createPageController(1);
    itemScrollController = ItemScrollController();
    itemScrollListener = ItemPositionsListener.create();
    scrollController = ScrollController(keepScrollOffset: true);
    clearPhotoViewControllers();
    noScroll = false;
    currentScale = 1.0;
    showFloatingButtonValue = 0;
    isOnEndBlankPage = false;
    chapterEndCharge.reset();
    index = 1;
    urls.clear();
    isLoading = true;
    tools = false;
    showSettings = false;
    requestedLoadingItems = [];
    update();
  }

  bool isFullScreen = false;
  Rect? _preFullscreenRect;
  bool _wasMaximized = false;

  void fullscreen() async {
    if (App.isDesktop) {
      if (isFullScreen) {
        isFullScreen = false;
        await windowManager.setFullScreen(false);
        if (_wasMaximized) {
          await windowManager.maximize();
        } else if (_preFullscreenRect != null) {
          await windowManager.setBounds(_preFullscreenRect!);
        }
      } else {
        isFullScreen = true;
        _wasMaximized = await windowManager.isMaximized();
        if (!_wasMaximized) {
          _preFullscreenRect = await windowManager.getBounds();
        }
        await windowManager.setFullScreen(true);
      }
    } else {
      const channel = MethodChannel("pica_comic/full_screen");
      channel.invokeMethod("set", !isFullScreen);
      isFullScreen = !isFullScreen;
    }
    WindowFrame.of(App.globalContext!).setWindowFrame(!isFullScreen);
    focusNode.requestFocus();
  }

  void handleKeyboard(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      bool reverse = appdata.settings[9] == "2" || appdata.settings[9] == "6";
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowRight:
          reverse ? jumpToLastPage() : jumpToNextPage();
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowLeft:
          reverse ? jumpToNextPage() : jumpToLastPage();
        case LogicalKeyboardKey.f12:
          fullscreen();
      }
    }
  }

  late final void Function() openEpsView;
}
