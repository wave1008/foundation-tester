// 本物の Appium Java Client での比較ベンチ。sut-ec-mobile の4シナリオ
// (Projects/sut-ec-mobile/Scenarios/*.swift)と同一ステップ列を「典型的な Java Client 作法」で実装:
//   - テストクラス相当ごとに IOSDriver 生成(=セッション作成)→ steps → quit()
//   - 要素操作は WebDriverWait(10s) + findElement(accessibility id / iOSNsPredicate) + click/sendKeys
// 出力: NDJSON(kind=class: wallMs/sessionMs/quitMs、kind=step: desc/ms)。
// 引数: <出力ファイル> <反復回数(warmup除く)> [mode: plain|tuned] [udid] [bundleId]
//   plain: クラス毎にセッション作成→quit(Java Client 既定の典型)
//   tuned: スイート全体で1ドライバ使い回し+usePrebuiltWDA+wdaLocalPort 固定+
//          waitForIdleTimeout/animationCoolOffTimeout=0。クラス間は terminateApp+activateApp
//          (既存エンジンの launch 意味論)で、その時間を sessionMs 列に記録する
// plain の launchApp 相当はセッション作成がアプリを起動するため独立ステップとしては計上しない
// (レポート側で sessionMs と分離して比較する)。

import io.appium.java_client.AppiumBy;
import io.appium.java_client.Setting;
import io.appium.java_client.ios.IOSDriver;
import io.appium.java_client.ios.options.XCUITestOptions;
import org.openqa.selenium.By;
import org.openqa.selenium.TimeoutException;
import org.openqa.selenium.WebElement;
import org.openqa.selenium.support.ui.ExpectedConditions;
import org.openqa.selenium.support.ui.WebDriverWait;

import java.io.FileWriter;
import java.io.PrintWriter;
import java.net.URL;
import java.time.Duration;
import java.util.List;
import java.util.function.Consumer;

public class PocJavaClientBench {

    static String udid = "8A590C3D-3B05-46F5-BC43-9791304A9969";
    static String bundleId = "com.sutec.mobile";
    static PrintWriter out;
    static IOSDriver driver;
    static WebDriverWait wait10;
    static String currentScenario;
    static int currentIter;
    static int stepIndex;

    static boolean tuned = false;

    public static void main(String[] args) throws Exception {
        String outPath = args[0];
        int iterations = Integer.parseInt(args[1]);
        if (args.length > 2) tuned = args[2].equals("tuned");
        if (args.length > 3) udid = args[3];
        if (args.length > 4) bundleId = args[4];
        out = new PrintWriter(new FileWriter(outPath, true), true);
        if (tuned) {
            createSessionWithRetry();  // スイート全体で1ドライバ(以降は再作成しない)
        }

        record Scen(String name, Consumer<Void> body) {}
        List<Scen> scenarios = List.of(
            new Scen("タブが正しく遷移すること", v -> tabNavigation()),
            new Scen("カートに商品を追加できること", v -> addToCart()),
            new Scen("検索で絞り込めること", v -> searchFilter()),
            new Scen("ログイン入力バリデーションが働くこと.S0010", v -> loginEmptyEmail()),
            new Scen("ログイン入力バリデーションが働くこと.S0020", v -> loginEmptyPassword()),
            new Scen("ログイン入力バリデーションが働くこと.S0030", v -> loginBlankBoth())
        );

        // iter 0 = warmup(集計から除外)
        for (int iter = 0; iter <= iterations; iter++) {
            for (Scen s : scenarios) {
                currentScenario = s.name();
                currentIter = iter;
                stepIndex = 0;
                long t0 = System.nanoTime();
                long sessionMs;
                if (tuned) {
                    // 使い回しドライバでアプリだけ再起動(既存エンジンの launch 意味論と揃える)
                    long tl = System.nanoTime();
                    try { driver.terminateApp(bundleId); } catch (Exception ignored) {}
                    driver.activateApp(bundleId);
                    sessionMs = (System.nanoTime() - tl) / 1_000_000;
                } else {
                    sessionMs = createSessionWithRetry();
                }
                boolean passed = true;
                String error = null;
                try {
                    s.body().accept(null);
                } catch (Exception e) {
                    passed = false;
                    error = e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()).replace("\"", "'");
                    if (error.length() > 200) error = error.substring(0, 200);
                }
                long tQuit = System.nanoTime();
                if (!tuned) {
                    try { driver.quit(); } catch (Exception ignored) {}
                }
                long quitMs = (System.nanoTime() - tQuit) / 1_000_000;
                long wallMs = (System.nanoTime() - t0) / 1_000_000;
                out.printf("{\"kind\":\"class\",\"scenario\":\"%s\",\"iter\":%d,\"warmup\":%b,\"passed\":%b,\"wallMs\":%d,\"sessionMs\":%d,\"quitMs\":%d%s}%n",
                        s.name(), iter, iter == 0, passed, wallMs, sessionMs, quitMs,
                        error == null ? "" : ",\"error\":\"" + error + "\"");
                System.out.printf("[%d] %s: %s wall=%.1fs session=%.1fs%n",
                        iter, s.name(), passed ? "PASS" : "FAIL", wallMs / 1000.0, sessionMs / 1000.0);
            }
        }
        if (tuned) {
            try { driver.quit(); } catch (Exception ignored) {}
        }
        out.close();
    }

    /// appium-ios-simulator の状態誤認バグ(Simulator is not in 'Shutdown' state)は
    /// Swift 側 AppiumDriver と同条件になるよう 5s 待って1回だけ再試行する
    static long createSessionWithRetry() {
        long t0 = System.nanoTime();
        XCUITestOptions options = new XCUITestOptions()
                .setUdid(udid)
                .setBundleId(bundleId)
                .setNoReset(true)
                .setWdaLaunchTimeout(Duration.ofMillis(180000))
                .setNewCommandTimeout(Duration.ofSeconds(60));
        if (tuned) {
            options.setUsePrebuiltWda(true).setWdaLocalPort(8100);
            options.setNewCommandTimeout(Duration.ZERO);  // 使い回しのためアイドル切断を無効化
        }
        for (int attempt = 0; ; attempt++) {
            try {
                driver = new IOSDriver(url(), options);
                break;
            } catch (Exception e) {
                if (attempt == 0 && String.valueOf(e.getMessage()).contains("Shutdown")) {
                    sleep(5000);
                    continue;
                }
                throw new RuntimeException(e);
            }
        }
        if (tuned) {
            driver.setSetting(Setting.WAIT_FOR_IDLE_TIMEOUT, 0);
            driver.setSetting("animationCoolOffTimeout", 0);
        }
        wait10 = new WebDriverWait(driver, Duration.ofSeconds(10));
        return (System.nanoTime() - t0) / 1_000_000;
    }

    static URL url() {
        try { return new URL("http://127.0.0.1:4723"); } catch (Exception e) { throw new RuntimeException(e); }
    }

    // MARK: - ステップ原語(計測付き)

    static void step(String desc, Runnable body) {
        stepIndex++;
        long t0 = System.nanoTime();
        body.run();
        long ms = (System.nanoTime() - t0) / 1_000_000;
        out.printf("{\"kind\":\"step\",\"scenario\":\"%s\",\"iter\":%d,\"index\":%d,\"desc\":\"%s\",\"ms\":%d}%n",
                currentScenario, currentIter, stepIndex, desc, ms);
    }

    static void tap(String accessibilityId) {
        step("tap #" + accessibilityId, () ->
            wait10.until(ExpectedConditions.presenceOfElementLocated(
                    AppiumBy.accessibilityId(accessibilityId))).click());
    }

    static void existText(String label) {
        step("exist \"" + label + "\"", () ->
            wait10.until(ExpectedConditions.presenceOfElementLocated(
                    AppiumBy.iOSNsPredicateString("label == \"" + label + "\""))));
    }

    static void existId(String accessibilityId) {
        step("exist #" + accessibilityId, () ->
            wait10.until(ExpectedConditions.presenceOfElementLocated(
                    AppiumBy.accessibilityId(accessibilityId))));
    }

    /// ifCanSelect 相当: 1s だけ探して居ればタップ、居なければ何もしない
    static void tapIfPresent(String accessibilityId) {
        step("ifCanSelect #" + accessibilityId, () -> {
            try {
                WebElement el = new WebDriverWait(driver, Duration.ofSeconds(1))
                        .until(ExpectedConditions.presenceOfElementLocated(
                                AppiumBy.accessibilityId(accessibilityId)));
                el.click();
            } catch (TimeoutException ignored) {
            }
        });
    }

    static void type(String accessibilityId, String text) {
        step("type #" + accessibilityId, () -> {
            By by = AppiumBy.accessibilityId(accessibilityId);
            WebElement el = wait10.until(ExpectedConditions.presenceOfElementLocated(by));
            el.click();  // シナリオと同じ「フォーカスしてから入力」
            el.sendKeys(text);
        });
    }

    static void sleepStep(double seconds) {
        step("wait " + seconds + "s", () -> sleep((long) (seconds * 1000)));
    }

    static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { throw new RuntimeException(e); }
    }

    // MARK: - シナリオ(Scenarios/*.swift と同一ステップ列)

    static void emptyCart() { tapIfPresent("btn_remove_fashion_5"); }

    static void tabNavigation() {
        tap("tab_cart"); emptyCart(); existText("カートは空です");
        tap("tab_home"); existText("SUT Store"); existText("おすすめ");
        tap("tab_search"); existText("カテゴリから探す");
        tap("tab_wishlist"); existText("お気に入りは空です");
        tap("tab_account"); existText("ログイン / 登録");
        tap("tab_cart"); existText("カートは空です");
        tap("tab_home"); tap("product_card_fashion_5"); tap("btn_add_to_cart");
        tap("btn_open_cart"); tap("tab_home");
        existText("SUT Store"); existText("おすすめ");
        tap("tab_cart"); tap("btn_remove_fashion_5"); existText("カートは空です");
    }

    static void addToCart() {
        tap("tab_cart"); emptyCart(); existText("カートは空です");
        tap("tab_home"); tap("product_card_fashion_5");
        existText("在庫あり"); existId("btn_add_to_cart");
        tap("btn_add_to_cart"); sleepStep(1.0); tap("btn_open_cart");
        existText("合計"); existText("ミニマルデザイン腕時計");
        tap("btn_remove_fashion_5"); existText("カートは空です");
    }

    static void searchFilter() {
        tap("tab_home"); tap("tab_search"); existText("カテゴリから探す");
        tap("chip_category_fashion"); existText("メンズ デニムジャケット");
        tap("chip_category_electronics"); existText("ワイヤレスイヤホン Pro");
    }

    static void openLogin() {
        tapIfPresent("btn_back");
        tap("tab_account");
        tap("btn_login");
        existId("field_email");
    }

    static void loginEmptyEmail() {
        openLogin();
        type("field_password", "somepassword");
        tap("btn_login");
        existText("ログインに失敗しました");
    }

    static void loginEmptyPassword() {
        openLogin();
        type("field_email", "someone@example.com");
        tap("btn_login");
        existText("ログインに失敗しました");
    }

    static void loginBlankBoth() {
        openLogin();
        type("field_email", "   ");
        type("field_password", "   ");
        tap("btn_login");
        existText("ログインに失敗しました");
    }
}
