import 'package:flutter/material.dart';
import 'map_screen.dart';
import 'users_screen.dart';

class DashboardScreen extends StatefulWidget {
  final String token;
  DashboardScreen({required this.token});

  @override
  _DashboardScreenState createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      UsersScreen(token: widget.token),
      MapScreen(token: widget.token),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;

        return Scaffold(
          appBar: AppBar(title: Text('Admin Dashboard')),
          body: SafeArea(
            child: isWide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _selectedIndex,
                        onDestinationSelected: (index) {
                          setState(() {
                            _selectedIndex = index;
                          });
                        },
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          NavigationRailDestination(
                            icon: Icon(Icons.people),
                            label: Text('Users'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.map),
                            label: Text('Live Map'),
                          ),
                        ],
                      ),
                      Expanded(child: screens[_selectedIndex]),
                    ],
                  )
                : screens[_selectedIndex],
          ),
          bottomNavigationBar: isWide
              ? null
              : BottomNavigationBar(
                  currentIndex: _selectedIndex,
                  onTap: (index) {
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                  items: [
                    BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Users'),
                    BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Live Map'),
                  ],
                ),
        );
      },
    );
  }
}
