import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String _locale(BuildContext context) =>
    Localizations.localeOf(context).toLanguageTag();

String formatLocalizedNumber(BuildContext context, num value) {
  return NumberFormat.decimalPattern(_locale(context)).format(value);
}

String formatLocalizedDateTime(BuildContext context, DateTime value) {
  final locale = _locale(context);
  return DateFormat.yMMMd(locale).add_jm().format(value.toLocal());
}

String formatLocalizedTime(BuildContext context, DateTime value) {
  return DateFormat.jm(_locale(context)).format(value.toLocal());
}