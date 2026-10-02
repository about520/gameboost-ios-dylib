/*
 * find_targets.js —— Frida 侦察脚本
 *
 * 作用：把目标 App 里「像广告的类」和「像发奖的方法」全部列出来，
 *      用来校准插件里的关键词表，以及确认 hook 该往哪打。
 *
 * 用法（需越狱设备 或 已砸壳 IPA + frida-server）：
 *   frida -U -f com.example.game -l find_targets.js --no-pause
 *
 * 或者用 objection：
 *   objection -g com.example.game explore
 */

'use strict';

if (!ObjC.available) {
    console.log('[-] 当前进程没有 Objective-C 运行时，脚本退出');
} else {
    main();
}

function main() {
    const AD_CLASS_RE = /(Interstitial|Rewarded|RewardVideo|VideoAd|Splash|AppOpen|Advert|FullScreenAd|ExpressAd)/i;
    const AD_DENY_RE  = /(Banner|Adapter|Manager|Configuration|Request|Loader|Cache)/i;

    const SHOW_RE = /^(show|present|display|play|start|load|request|render|open)/i;

    const VERBS = ['add', 'give', 'grant', 'reward', 'claim', 'receive', 'earn',
                   'gain', 'plus', 'increase', 'insert', 'put', 'update', 'bonus',
                   'collect', 'obtain', 'acquire', 'credit', 'deposit'];
    const RES   = ['coin', 'gold', 'money', 'cash', 'diamond', 'gem', 'jewel',
                   'credit', 'point', 'balance', 'reward', 'score', 'star',
                   'ticket', 'energy', 'life', 'hp', 'dollar', 'yuan', 'wallet',
                   'voucher', 'coupon', 'bean', 'shell'];
    const DENY  = ['did', 'will', 'should', 'animation', 'animate', 'label', 'text',
                   'string', 'format', 'icon', 'image', 'color', 'font', 'frame',
                   'position', 'layer', 'display', 'notify', 'log', 'analytics',
                   'event', 'track', 'report', 'request', 'http', 'url', 'json',
                   'dict', 'array', 'callback', 'delegate', 'observer', 'bind',
                   'cell', 'init', 'alloc', 'copy', 'description', 'debug'];

    const allClasses = Object.keys(ObjC.classes);
    console.log('[+] 进程内 ObjC 类总数: ' + allClasses.length);

    const adClasses = [];
    const rewardHits = [];

    for (const name of allClasses) {
        // ——— 广告类
        if (AD_CLASS_RE.test(name) && !AD_DENY_RE.test(name)) {
            const showMethods = ownMethodsOf(name).filter(m => SHOW_RE.test(m.replace(/^[-+]/, '')));
            if (showMethods.length > 0) {
                adClasses.push({ name, methods: showMethods });
            }
        }

        // ——— 发奖方法
        const owner = ObjC.classes[name];
        const methods = ownMethodsOf(name);
        for (const raw of methods) {
            const sel = raw.replace(/^[-+]/, '');
            const low = sel.toLowerCase();

            if (DENY.some(d => low.includes(d))) continue;
            if (!VERBS.some(v => low.includes(v))) continue;
            if (!RES.some(r => low.includes(r))) continue;

            const enc = typeEncodingOf(owner, sel);
            rewardHits.push({ cls: name, sel, enc: enc || '(取不到)' });
        }
    }

    // ——— 输出
    console.log('\n======= 疑似广告类 =======');
    if (adClasses.length === 0) {
        console.log('(没有匹配到。说明广告 SDK 可能用了完全不相关的类名，');
        console.log(' 这时主要靠 L2 的 presentViewController 拦截 + L3 兜底关闭。)');
    } else {
        for (const c of adClasses) {
            console.log('\n● ' + c.name);
            for (const m of c.methods) {
                const sel = m.replace(/^[-+]/, '');
                const enc = typeEncodingOf(ObjC.classes[c.name], sel);
                console.log('    ' + m + '        ' + (enc || ''));
            }
        }
    }

    console.log('\n======= 疑似发奖方法（' + rewardHits.length + ' 个）=======');
    for (const h of rewardHits.slice(0, 300)) {
        console.log('  ' + h.cls + '  -[' + h.sel + ']   ' + h.enc);
    }
    if (rewardHits.length > 300) {
        console.log('  ... 还有 ' + (rewardHits.length - 300) + ' 个未显示');
    }

    console.log('\n提示：把上面「疑似广告类」的类名和展示方法名补进 GBAdHooks.m 的自动发现规则，');
    console.log('     把「疑似发奖方法」里确认过的补进 GBRewardHooks.m 的关键词表，命中率会明显提升。');
}

function ownMethodsOf(className) {
    try {
        const arr = ObjC.classes[className].$ownMethods;
        return arr ? Array.prototype.slice.call(arr) : [];
    } catch (e) {
        return [];
    }
}

function typeEncodingOf(owner, sel) {
    try {
        const p = ObjC.selector(sel);
        const m = ObjC.api.class_getInstanceMethod(owner.handle, p);
        if (m.isNull()) return null;
        const enc = ObjC.api.method_getTypeEncoding(m);
        return enc.isNull() ? null : enc.readUtf8String();
    } catch (e) {
        return null;
    }
}
