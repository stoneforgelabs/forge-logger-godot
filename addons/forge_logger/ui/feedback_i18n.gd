class_name ForgeLoggerFeedbackI18n
extends RefCounted
## Language of the in-game feedback form and formatting of its fixed labels
## (ForgeLoggerFeedbackTexts): locale matching, `{name}` placeholders, ICU
## `{n, plural, one {…} other {…}}` and price points. Mirrors the web form
## (apps/forge-logger-fe/src/lib/feedback-public.ts) closely enough that a
## player sees the same wording in the game and in the browser.


## Maps a locale tag (`pt_BR`, `de-AT`, `zh-TW`) to a supported form locale:
## exact match first, then by language. Empty when the language is not
## supported at all.
static func match_locale(tag: String) -> String:
	var normalized: String = tag.strip_edges().replace("_", "-").to_lower()
	if normalized.is_empty():
		return ""
	for locale: String in ForgeLoggerFeedbackTexts.LOCALES:
		if locale.to_lower() == normalized:
			return locale
	var language: String = normalized.split("-")[0]
	for locale: String in ForgeLoggerFeedbackTexts.LOCALES:
		if locale.split("-")[0].to_lower() == language:
			return locale
	return ""


## Locale of the form, in order: an explicit choice of the game, the game's
## current language (TranslationServer — the player's language, like the
## browser's on the web), the link's preset, English.
static func resolve_locale(explicit: String, game_locale: String, link_default: String) -> String:
	for candidate: String in [explicit, game_locale, link_default]:
		var matched: String = match_locale(candidate)
		if not matched.is_empty():
			return matched
	return ForgeLoggerFeedbackTexts.DEFAULT_LOCALE


## A fixed label in `locale`, formatted with `args` (English when missing).
static func text(locale: String, key: String, args: Dictionary = {}) -> String:
	var texts: Dictionary = ForgeLoggerFeedbackTexts.TEXTS.get(locale, {}) as Dictionary
	var message: String = str(texts.get(key, ""))
	if message.is_empty():
		var fallback: Dictionary = ForgeLoggerFeedbackTexts.TEXTS.get(ForgeLoggerFeedbackTexts.DEFAULT_LOCALE, {}) as Dictionary
		message = str(fallback.get(key, key))
	return format_message(message, locale, args)


## CLDR plural category of a whole number in `locale` (one, few, many, other).
static func plural_category(locale: String, n: int) -> String:
	var language: String = locale.split("-")[0].to_lower()
	var abs_n: int = absi(n)
	match language:
		"fr", "pt":
			return "one" if abs_n == 0 or abs_n == 1 else "other"
		"cs", "sk":
			if abs_n == 1:
				return "one"
			if abs_n >= 2 and abs_n <= 4:
				return "few"
			return "other"
		"ru", "uk":
			var mod10: int = abs_n % 10
			var mod100: int = abs_n % 100
			if mod10 == 1 and mod100 != 11:
				return "one"
			if mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14):
				return "few"
			return "many"
		"ja", "zh", "ko":
			return "other"
		_:
			return "one" if abs_n == 1 else "other"


## Resolves `{name}` and `{name, plural, …}` (with `#`) in an ICU message.
static func format_message(message: String, locale: String, args: Dictionary) -> String:
	var out: String = ""
	var i: int = 0
	var length: int = message.length()
	while i < length:
		var c: String = message[i]
		if c == "{":
			var end: int = _matching_brace(message, i)
			if end < 0:
				out += message.substr(i)
				break
			out += _format_argument(message.substr(i + 1, end - i - 1), locale, args)
			i = end + 1
		else:
			out += c
			i += 1
	return out


## A price point as the player reads it: `€6`, `6 €+`, `4,99 Kč`, `$4.99`.
static func format_price(amount: float, currency: String, locale: String, or_more: bool = false) -> String:
	var language: String = locale.split("-")[0].to_lower()
	var decimal_comma: bool = language in ["de", "fr", "es", "pt", "ru", "cs"]
	var number: String = ""
	if is_equal_approx(amount, roundf(amount)):
		number = str(int(roundf(amount)))
	else:
		number = "%.2f" % amount
		if decimal_comma:
			number = number.replace(".", ",")
	var code: String = currency.to_upper()
	var symbols: Dictionary = {
		"EUR": "€", "USD": "$", "GBP": "£", "JPY": "¥", "CNY": "¥", "BRL": "R$",
		"CZK": "Kč", "PLN": "zł", "RUB": "₽", "CAD": "CA$", "AUD": "A$",
	}
	var text_value: String = ""
	if not symbols.has(code):
		text_value = "%s %s" % [number, code]
	elif code in ["CZK", "PLN", "RUB"] or (code == "EUR" and language != "en"):
		text_value = "%s %s" % [number, symbols[code]]
	else:
		text_value = "%s%s" % [symbols[code], number]
	return text_value + "+" if or_more else text_value


static func _format_argument(inner: String, locale: String, args: Dictionary) -> String:
	var parts: PackedStringArray = inner.split(",", true, 2)
	var arg_name: String = parts[0].strip_edges()
	if parts.size() >= 3 and parts[1].strip_edges() == "plural":
		var n: int = int(args.get(arg_name, 0))
		var cases: Dictionary = _parse_plural_cases(parts[2])
		var exact: String = "=%d" % n
		var category: String = exact if cases.has(exact) else plural_category(locale, n)
		var chosen: String = str(cases.get(category, cases.get("other", "")))
		return format_message(chosen.replace("#", str(n)), locale, args)
	if args.has(arg_name):
		return str(args[arg_name])
	return "{%s}" % inner


static func _parse_plural_cases(text: String) -> Dictionary:
	var cases: Dictionary = {}
	var i: int = 0
	var length: int = text.length()
	while i < length:
		while i < length and text[i] in [" ", "\t", "\n"]:
			i += 1
		var start: int = i
		while i < length and text[i] != "{" and not text[i] in [" ", "\t", "\n"]:
			i += 1
		var selector: String = text.substr(start, i - start)
		while i < length and text[i] != "{":
			i += 1
		if i >= length:
			break
		var end: int = _matching_brace(text, i)
		if end < 0:
			break
		if not selector.is_empty():
			cases[selector] = text.substr(i + 1, end - i - 1)
		i = end + 1
	return cases


static func _matching_brace(text: String, open_index: int) -> int:
	var depth: int = 0
	for i: int in range(open_index, text.length()):
		var c: String = text[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return i
	return -1
