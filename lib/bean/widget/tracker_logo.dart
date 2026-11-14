import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:kazumi/services/tracking/tracker.dart';

void registerTrackerLogoLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Mihon tracker artwork'],
      await rootBundle.loadString('licenses/mihon/LICENSE'),
    );
  });
}

class TrackerLogo extends StatelessWidget {
  const TrackerLogo({super.key, required this.trackerId, this.size = 40});

  final TrackerId trackerId;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SvgPicture.asset(
      'assets/images/tracker_${trackerId.name}.svg',
      width: size,
      height: size,
      semanticsLabel: trackerId == TrackerId.bangumi ? 'Bangumi' : 'AniList',
    ),
  );
}
